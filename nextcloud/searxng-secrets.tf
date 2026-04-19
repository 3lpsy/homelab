resource "kubernetes_namespace" "searxng" {
  metadata {
    name = "searxng"
  }
}

resource "kubernetes_service_account" "searxng" {
  metadata {
    name      = "searxng"
    namespace = kubernetes_namespace.searxng.metadata[0].name
  }
  automount_service_account_token = true
}

resource "kubernetes_role" "searxng_tailscale" {
  metadata {
    name      = "searxng-tailscale"
    namespace = kubernetes_namespace.searxng.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["create"]
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["searxng-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "searxng_tailscale" {
  metadata {
    name      = "searxng-tailscale"
    namespace = kubernetes_namespace.searxng.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.searxng_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.searxng.metadata[0].name
    namespace = kubernetes_namespace.searxng.metadata[0].name
  }
}

resource "random_password" "searxng_secret_key" {
  length  = 64
  special = false
}

resource "headscale_pre_auth_key" "searxng_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.searxng_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "searxng_tailscale_auth" {
  metadata {
    name      = "searxng-tailscale-auth"
    namespace = kubernetes_namespace.searxng.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.searxng_server.key
  }
}

module "searxng-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.searxng_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "vault_kv_secret_v2" "searxng_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "searxng/config"
  data_json = jsonencode({
    secret_key = random_password.searxng_secret_key.result
  })
}

resource "vault_kv_secret_v2" "searxng_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "searxng/tls"
  data_json = jsonencode({
    fullchain_pem = module.searxng-tls.fullchain_pem
    privkey_pem   = module.searxng-tls.privkey_pem
  })
}

resource "vault_policy" "searxng" {
  name = "searxng-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/searxng/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "searxng" {
  backend                          = "kubernetes"
  role_name                        = "searxng"
  bound_service_account_names      = ["searxng"]
  bound_service_account_namespaces = ["searxng"]
  token_policies                   = [vault_policy.searxng.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "searxng_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-searxng"
      namespace = kubernetes_namespace.searxng.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "searxng-secrets"
          type       = "Opaque"
          data = [
            {
              objectName = "searxng_secret_key"
              key        = "secret_key"
            }
          ]
        },
        {
          secretName = "searxng-tls"
          type       = "kubernetes.io/tls"
          data = [
            {
              objectName = "searxng_tls_crt"
              key        = "tls.crt"
            },
            {
              objectName = "searxng_tls_key"
              key        = "tls.key"
            }
          ]
        }
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "searxng"
        objects = yamlencode([
          {
            objectName = "searxng_secret_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/searxng/config"
            secretKey  = "secret_key"
          },
          {
            objectName = "searxng_tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/searxng/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "searxng_tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/searxng/tls"
            secretKey  = "privkey_pem"
          }
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.searxng,
    vault_kubernetes_auth_backend_role.searxng,
    vault_kv_secret_v2.searxng_config,
    vault_kv_secret_v2.searxng_tls,
    vault_policy.searxng
  ]
}
