resource "random_password" "ntfy_user_passwords" {
  for_each = var.ntfy_users
  length   = 32
  special  = false
}

resource "kubernetes_service_account" "ntfy" {
  metadata {
    name      = "ntfy"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_secret" "ntfy_tailscale_state" {
  metadata {
    name      = "ntfy-tailscale-state"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  type = "Opaque"

  lifecycle {
    ignore_changes = [data, type]
  }
}

resource "kubernetes_role" "ntfy_tailscale" {
  metadata {
    name      = "ntfy-tailscale"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["ntfy-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "ntfy_tailscale" {
  metadata {
    name      = "ntfy-tailscale"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.ntfy_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.ntfy.metadata[0].name
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
}

resource "headscale_pre_auth_key" "ntfy_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.ntfy_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "ntfy_tailscale_auth" {
  metadata {
    name      = "ntfy-tailscale-auth"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.ntfy_server.key
  }
}

module "ntfy-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.ntfy_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "vault_kv_secret_v2" "ntfy_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "ntfy/config"
  data_json = jsonencode({
    for user, role in var.ntfy_users :
    "password_${user}" => random_password.ntfy_user_passwords[user].result
  })
}

resource "vault_kv_secret_v2" "ntfy_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "ntfy/tls"
  data_json = jsonencode({
    fullchain_pem = module.ntfy-tls.fullchain_pem
    privkey_pem   = module.ntfy-tls.privkey_pem
  })

  # tls-rotator (services/tls-rotator.tf) owns rotation post-bootstrap.
  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "vault_policy" "ntfy" {
  name = "ntfy-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/ntfy/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "ntfy" {
  backend                          = "kubernetes"
  role_name                        = "ntfy"
  bound_service_account_names      = ["ntfy"]
  bound_service_account_namespaces = ["monitoring"]
  token_policies                   = [vault_policy.ntfy.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "ntfy_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-ntfy"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "ntfy-tls"
          type       = "kubernetes.io/tls"
          data = [
            { objectName = "tls_crt", key = "tls.crt" },
            { objectName = "tls_key", key = "tls.key" },
          ]
        },
        # Synced for Reloader to watch — pod restarts on rotation, then the
        # seed-users init container re-applies passwords via `ntfy user add`.
        # The init container reads passwords from the CSI volume directly
        # (not this k8s Secret), so no consumer change is needed.
        {
          secretName = "ntfy-user-passwords"
          type       = "Opaque"
          data = [
            for user in keys(var.ntfy_users) :
            { objectName = "password_${user}", key = "password_${user}" }
          ]
        },
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "ntfy"
        # User passwords mount as files at /mnt/secrets/password_<user>.
        # The seed-users init container reads them and seeds the SQLite
        # auth-file via `ntfy user add`, so credentials never land in any
        # ConfigMap (and therefore never in Velero backup tarballs).
        objects = yamlencode(concat(
          [
            {
              objectName = "tls_crt"
              secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/ntfy/tls"
              secretKey  = "fullchain_pem"
            },
            {
              objectName = "tls_key"
              secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/ntfy/tls"
              secretKey  = "privkey_pem"
            },
          ],
          [
            for user in keys(var.ntfy_users) : {
              objectName = "password_${user}"
              secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/ntfy/config"
              secretKey  = "password_${user}"
            }
          ],
        ))
      }
    }
  }

  depends_on = [
    kubernetes_namespace.monitoring,
    vault_kubernetes_auth_backend_role.ntfy,
    vault_kv_secret_v2.ntfy_config,
    vault_kv_secret_v2.ntfy_tls,
    vault_policy.ntfy
  ]
}
