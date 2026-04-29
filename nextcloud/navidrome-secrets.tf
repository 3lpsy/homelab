resource "kubernetes_namespace" "navidrome" {
  metadata {
    name = "navidrome"
  }
}

resource "kubernetes_service_account" "navidrome" {
  metadata {
    name      = "navidrome"
    namespace = kubernetes_namespace.navidrome.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_secret" "navidrome_tailscale_state" {
  metadata {
    name      = "navidrome-tailscale-state"
    namespace = kubernetes_namespace.navidrome.metadata[0].name
  }
  type = "Opaque"

  lifecycle {
    ignore_changes = [data, type]
  }
}

resource "kubernetes_role" "navidrome_tailscale" {
  metadata {
    name      = "navidrome-tailscale"
    namespace = kubernetes_namespace.navidrome.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["navidrome-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "navidrome_tailscale" {
  metadata {
    name      = "navidrome-tailscale"
    namespace = kubernetes_namespace.navidrome.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.navidrome_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.navidrome.metadata[0].name
    namespace = kubernetes_namespace.navidrome.metadata[0].name
  }
}

resource "random_password" "navidrome_password" {
  length  = 32
  special = false
}

resource "headscale_pre_auth_key" "navidrome_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.music_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "navidrome_tailscale_auth" {
  metadata {
    name      = "navidrome-tailscale-auth"
    namespace = kubernetes_namespace.navidrome.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.navidrome_server.key
  }
}

module "navidrome-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.navidrome_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "vault_kv_secret_v2" "navidrome_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "navidrome/config"
  data_json = jsonencode({
    navidrome_password = random_password.navidrome_password.result
  })
}

resource "vault_kv_secret_v2" "navidrome_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "navidrome/tls"
  data_json = jsonencode({
    fullchain_pem = module.navidrome-tls.fullchain_pem
    privkey_pem   = module.navidrome-tls.privkey_pem
  })

  # tls-rotator (nextcloud/tls-rotator.tf) owns rotation post-bootstrap.
  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "vault_policy" "navidrome" {
  name = "navidrome-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/navidrome/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "navidrome" {
  backend                          = "kubernetes"
  role_name                        = "navidrome"
  bound_service_account_names      = ["navidrome"]
  bound_service_account_namespaces = ["navidrome"]
  token_policies                   = [vault_policy.navidrome.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "navidrome_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-navidrome"
      namespace = kubernetes_namespace.navidrome.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "navidrome-secrets"
          type       = "Opaque"
          data = [
            {
              objectName = "navidrome_password"
              key        = "navidrome_password"
            }
          ]
        },
        {
          secretName = "navidrome-tls"
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
        roleName     = "navidrome"
        objects = yamlencode([
          {
            objectName = "navidrome_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/navidrome/config"
            secretKey  = "navidrome_password"
          },
          {
            objectName = "tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/navidrome/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/navidrome/tls"
            secretKey  = "privkey_pem"
          }
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.navidrome,
    vault_kubernetes_auth_backend_role.navidrome,
    vault_kv_secret_v2.navidrome_config,
    vault_kv_secret_v2.navidrome_tls,
    vault_policy.navidrome
  ]
}
