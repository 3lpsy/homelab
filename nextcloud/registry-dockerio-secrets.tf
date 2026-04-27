resource "kubernetes_namespace" "registry_dockerio" {
  metadata {
    name = "registry-dockerio"
  }
}

resource "kubernetes_service_account" "registry_dockerio" {
  metadata {
    name      = "registry-dockerio"
    namespace = kubernetes_namespace.registry_dockerio.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_secret" "registry_dockerio_tailscale_state" {
  metadata {
    name      = "registry-dockerio-tailscale-state"
    namespace = kubernetes_namespace.registry_dockerio.metadata[0].name
  }
  type = "Opaque"

  lifecycle {
    ignore_changes = [data, type]
  }
}

resource "kubernetes_role" "registry_dockerio_tailscale" {
  metadata {
    name      = "registry-dockerio-tailscale"
    namespace = kubernetes_namespace.registry_dockerio.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["registry-dockerio-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "registry_dockerio_tailscale" {
  metadata {
    name      = "registry-dockerio-tailscale"
    namespace = kubernetes_namespace.registry_dockerio.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.registry_dockerio_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.registry_dockerio.metadata[0].name
    namespace = kubernetes_namespace.registry_dockerio.metadata[0].name
  }
}

# Per-deployment pre-auth key. Future sibling mirrors (registry-quayio, etc.)
# get their own pre-auth key resources but all bind to the same shared
# headscale user "registry_proxy_server_user" so they land in one ACL group.
resource "headscale_pre_auth_key" "registry_dockerio_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.registry_proxy_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "registry_dockerio_tailscale_auth" {
  metadata {
    name      = "registry-dockerio-tailscale-auth"
    namespace = kubernetes_namespace.registry_dockerio.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.registry_dockerio_server.key
  }
}

module "registry-dockerio-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.registry_dockerio_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "vault_kv_secret_v2" "registry_dockerio_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "registry-dockerio/tls"
  data_json = jsonencode({
    fullchain_pem = module.registry-dockerio-tls.fullchain_pem
    privkey_pem   = module.registry-dockerio-tls.privkey_pem
  })

  # tls-rotator owns rotation post-bootstrap.
  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "vault_policy" "registry_dockerio" {
  name = "registry-dockerio-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/registry-dockerio/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "registry_dockerio" {
  backend                          = "kubernetes"
  role_name                        = "registry-dockerio"
  bound_service_account_names      = ["registry-dockerio"]
  bound_service_account_namespaces = ["registry-dockerio"]
  token_policies                   = [vault_policy.registry_dockerio.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "registry_dockerio_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-registry-dockerio"
      namespace = kubernetes_namespace.registry_dockerio.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "registry-dockerio-tls"
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
        roleName     = "registry-dockerio"
        objects = yamlencode([
          {
            objectName = "tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/registry-dockerio/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/registry-dockerio/tls"
            secretKey  = "privkey_pem"
          }
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.registry_dockerio,
    vault_kubernetes_auth_backend_role.registry_dockerio,
    vault_kv_secret_v2.registry_dockerio_tls,
    vault_policy.registry_dockerio
  ]
}
