resource "kubernetes_namespace" "registry_proxy" {
  metadata {
    name = "registry-proxy"
  }
}

resource "kubernetes_service_account" "registry_proxy" {
  metadata {
    name      = "registry-proxy"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_secret" "registry_proxy_tailscale_state" {
  metadata {
    name      = "registry-proxy-tailscale-state"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }
  type = "Opaque"

  lifecycle {
    ignore_changes = [data, type]
  }
}

resource "kubernetes_role" "registry_proxy_tailscale" {
  metadata {
    name      = "registry-proxy-tailscale"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["registry-proxy-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "registry_proxy_tailscale" {
  metadata {
    name      = "registry-proxy-tailscale"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.registry_proxy_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.registry_proxy.metadata[0].name
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }
}

resource "headscale_pre_auth_key" "registry_proxy_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.registry_proxy_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "registry_proxy_tailscale_auth" {
  metadata {
    name      = "registry-proxy-tailscale-auth"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.registry_proxy_server.key
  }
}

module "registry-proxy-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.registry_proxy_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "vault_kv_secret_v2" "registry_proxy_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "registry-proxy/tls"
  data_json = jsonencode({
    fullchain_pem = module.registry-proxy-tls.fullchain_pem
    privkey_pem   = module.registry-proxy-tls.privkey_pem
  })

  # tls-rotator owns rotation post-bootstrap.
  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "vault_policy" "registry_proxy" {
  name = "registry-proxy-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/registry-proxy/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "registry_proxy" {
  backend                          = "kubernetes"
  role_name                        = "registry-proxy"
  bound_service_account_names      = ["registry-proxy"]
  bound_service_account_namespaces = ["registry-proxy"]
  token_policies                   = [vault_policy.registry_proxy.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "registry_proxy_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-registry-proxy"
      namespace = kubernetes_namespace.registry_proxy.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "registry-proxy-tls"
          type       = "kubernetes.io/tls"
          data = [
            {
              objectName = "tls_crt"
              key        = "tls.crt"
            },
            {
              objectName = "tls_key"
              key        = "tls.key"
            }
          ]
        }
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "registry-proxy"
        objects = yamlencode([
          {
            objectName = "tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/registry-proxy/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/registry-proxy/tls"
            secretKey  = "privkey_pem"
          }
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.registry_proxy,
    vault_kubernetes_auth_backend_role.registry_proxy,
    vault_kv_secret_v2.registry_proxy_tls,
    vault_policy.registry_proxy
  ]
}
