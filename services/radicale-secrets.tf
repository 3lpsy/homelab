resource "kubernetes_namespace" "radicale" {
  metadata {
    name = "radicale"
  }
}

resource "kubernetes_service_account" "radicale" {
  metadata {
    name      = "radicale"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_secret" "radicale_tailscale_state" {
  metadata {
    name      = "radicale-tailscale-state"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }
  type = "Opaque"

  lifecycle {
    ignore_changes = [data, type]
  }
}

resource "kubernetes_role" "radicale_tailscale" {
  metadata {
    name      = "radicale-tailscale"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["radicale-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "radicale_tailscale" {
  metadata {
    name      = "radicale-tailscale"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.radicale_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.radicale.metadata[0].name
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }
}

resource "random_password" "radicale_password" {
  length  = 32
  special = false
}

resource "headscale_pre_auth_key" "radicale_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.calendar_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "radicale_tailscale_auth" {
  metadata {
    name      = "radicale-tailscale-auth"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.radicale_server.key
  }
}

module "radicale-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.radicale_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "vault_kv_secret_v2" "radicale_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "radicale/config"
  data_json = jsonencode({
    radicale_password = random_password.radicale_password.result
  })
}

resource "vault_kv_secret_v2" "radicale_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "radicale/tls"
  data_json = jsonencode({
    fullchain_pem = module.radicale-tls.fullchain_pem
    privkey_pem   = module.radicale-tls.privkey_pem
  })

  # tls-rotator (services/tls-rotator.tf) owns rotation post-bootstrap.
  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "vault_policy" "radicale" {
  name = "radicale-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/radicale/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "radicale" {
  backend                          = "kubernetes"
  role_name                        = "radicale"
  bound_service_account_names      = ["radicale"]
  bound_service_account_namespaces = ["radicale"]
  token_policies                   = [vault_policy.radicale.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "radicale_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-radicale"
      namespace = kubernetes_namespace.radicale.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "radicale-secrets"
          type       = "Opaque"
          data = [
            {
              objectName = "radicale_password"
              key        = "radicale_password"
            }
          ]
        },
        {
          secretName = "radicale-tls"
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
        roleName     = "radicale"
        objects = yamlencode([
          {
            objectName = "radicale_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/radicale/config"
            secretKey  = "radicale_password"
          },
          {
            objectName = "tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/radicale/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/radicale/tls"
            secretKey  = "privkey_pem"
          }
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.radicale,
    vault_kubernetes_auth_backend_role.radicale,
    vault_kv_secret_v2.radicale_config,
    vault_kv_secret_v2.radicale_tls,
    vault_policy.radicale
  ]
}

