# In-cluster registry pull secret for the `ingest` namespace.
# ingest-ui pulls its custom image from registry.<hs>.<magic> built by
# BuildKit Jobs in the builder namespace. Placed here as the only
# image-pulling consumer in this ns.
resource "kubernetes_secret" "ingest_registry_pull_secret" {
  metadata {
    name      = "registry-pull-secret"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${local.thunderbolt_registry}" = {
          username = "internal"
          password = random_password.registry_user_passwords["internal"].result
          auth     = base64encode("internal:${random_password.registry_user_passwords["internal"].result}")
        }
      }
    })
  }
}

resource "kubernetes_service_account" "ingest_ui" {
  metadata {
    name      = "ingest-ui"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_secret" "ingest_ui_tailscale_state" {
  metadata {
    name      = "ingest-ui-tailscale-state"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }
  type = "Opaque"

  lifecycle {
    ignore_changes = [data, type]
  }
}

resource "kubernetes_role" "ingest_ui_tailscale" {
  metadata {
    name      = "ingest-ui-tailscale"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["ingest-ui-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "ingest_ui_tailscale" {
  metadata {
    name      = "ingest-ui-tailscale"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.ingest_ui_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.ingest_ui.metadata[0].name
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }
}

# Per-user random_password. Add a name to var.ingest_ui_users to provision
# a new caller; rotate with `terraform apply -replace=random_password.ingest_ui_user_passwords[\"<name>\"]`.
resource "random_password" "ingest_ui_user_passwords" {
  for_each = toset(var.ingest_ui_users)
  length   = 32
  special  = false
}

# Bearer token shared between ingest-ui (validates inbound) and
# navidrome-ingest (sends Authorization: Bearer <token>). Stored at the
# same Vault path so both pods read the same value via their own
# read-scoped policies. Rotation = terraform apply -replace; Reloader
# rolls both pods.
resource "random_password" "ingest_internal_token" {
  length  = 48
  special = false
}

resource "headscale_pre_auth_key" "ingest_ui_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.ingest_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "ingest_ui_tailscale_auth" {
  metadata {
    name      = "ingest-ui-tailscale-auth"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.ingest_ui_server.key
  }
}

module "ingest-ui-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.ingest_ui_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

# One Vault KV entry per user under ingest-ui/users/<name> with key `password`.
resource "vault_kv_secret_v2" "ingest_ui_user" {
  for_each = toset(var.ingest_ui_users)

  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "ingest-ui/users/${each.key}"
  data_json = jsonencode({
    password = random_password.ingest_ui_user_passwords[each.key].result
  })
}

# Bearer token shared between ingest-ui (server) and navidrome-ingest (client).
resource "vault_kv_secret_v2" "ingest_internal" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "ingest-ui/internal"
  data_json = jsonencode({
    token = random_password.ingest_internal_token.result
  })
}

# Optional yt-dlp cookies (Netscape format). Empty when var.ytdlp_cookies
# is unset; the SPC still syncs an empty file, and server.py treats a
# zero-byte file as "no cookies, fall through to player_client tricks".
resource "vault_kv_secret_v2" "ytdlp_cookies" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "ingest-ui/ytdlp-cookies"
  data_json = jsonencode({
    cookies = var.ytdlp_cookies
  })
}

resource "vault_kv_secret_v2" "ingest_ui_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "ingest-ui/tls"
  data_json = jsonencode({
    fullchain_pem = module.ingest-ui-tls.fullchain_pem
    privkey_pem   = module.ingest-ui-tls.privkey_pem
  })

  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "vault_policy" "ingest_ui" {
  name = "ingest-ui-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/ingest-ui/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "ingest_ui" {
  backend                          = "kubernetes"
  role_name                        = "ingest-ui"
  bound_service_account_names      = ["ingest-ui"]
  bound_service_account_namespaces = ["ingest"]
  token_policies                   = [vault_policy.ingest_ui.name]
  token_ttl                        = 86400
}

# Single SPC syncs every user's password into one K8s secret with key
# `password_<name>`, plus the TLS keypair.
resource "kubernetes_manifest" "ingest_ui_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-ingest-ui"
      namespace = kubernetes_namespace.ingest.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "ingest-ui-users"
          type       = "Opaque"
          data = [
            for u in var.ingest_ui_users : {
              objectName = "password_${u}"
              key        = "password_${u}"
            }
          ]
        },
        {
          secretName = "ingest-ui-internal"
          type       = "Opaque"
          data = [
            { objectName = "internal_token", key = "internal_token" },
          ]
        },
        {
          secretName = "ingest-ui-ytdlp-cookies"
          type       = "Opaque"
          data = [
            { objectName = "ytdlp_cookies", key = "ytdlp_cookies" },
          ]
        },
        {
          secretName = "ingest-ui-tls"
          type       = "kubernetes.io/tls"
          data = [
            { objectName = "tls_crt", key = "tls.crt" },
            { objectName = "tls_key", key = "tls.key" },
          ]
        },
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "ingest-ui"
        objects = yamlencode(concat(
          [
            for u in var.ingest_ui_users : {
              objectName = "password_${u}"
              secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/ingest-ui/users/${u}"
              secretKey  = "password"
            }
          ],
          [
            {
              objectName = "internal_token"
              secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/ingest-ui/internal"
              secretKey  = "token"
            },
            {
              objectName = "ytdlp_cookies"
              secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/ingest-ui/ytdlp-cookies"
              secretKey  = "cookies"
            },
            {
              objectName = "tls_crt"
              secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/ingest-ui/tls"
              secretKey  = "fullchain_pem"
            },
            {
              objectName = "tls_key"
              secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/ingest-ui/tls"
              secretKey  = "privkey_pem"
            },
          ]
        ))
      }
    }
  }

  depends_on = [
    kubernetes_namespace.ingest,
    vault_kubernetes_auth_backend_role.ingest_ui,
    vault_kv_secret_v2.ingest_ui_user,
    vault_kv_secret_v2.ingest_internal,
    vault_kv_secret_v2.ytdlp_cookies,
    vault_kv_secret_v2.ingest_ui_tls,
    vault_policy.ingest_ui,
  ]
}
