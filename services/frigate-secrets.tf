resource "kubernetes_namespace" "frigate" {
  metadata {
    name = "frigate"
  }
}

resource "kubernetes_service_account" "frigate" {
  metadata {
    name      = "frigate"
    namespace = kubernetes_namespace.frigate.metadata[0].name
  }
  automount_service_account_token = false
}

# Pre-create the Tailscale sidecar's state Secret so the Role only needs
# get/update/patch (resource-scoped) and not a namespace-wide `create`.
# Tailscale's kube-store calls Get first; if the Secret exists it skips
# the Create path entirely.
resource "kubernetes_secret" "frigate_tailscale_state" {
  metadata {
    name      = "frigate-tailscale-state"
    namespace = kubernetes_namespace.frigate.metadata[0].name
  }
  type = "Opaque"

  lifecycle {
    ignore_changes = [data, type]
  }
}

resource "kubernetes_role" "frigate_tailscale" {
  metadata {
    name      = "frigate-tailscale"
    namespace = kubernetes_namespace.frigate.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["frigate-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "frigate_tailscale" {
  metadata {
    name      = "frigate-tailscale"
    namespace = kubernetes_namespace.frigate.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.frigate_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.frigate.metadata[0].name
    namespace = kubernetes_namespace.frigate.metadata[0].name
  }
}

resource "headscale_pre_auth_key" "frigate_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.frigate_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "frigate_tailscale_auth" {
  metadata {
    name      = "frigate-tailscale-auth"
    namespace = kubernetes_namespace.frigate.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.frigate_server.key
  }
}

# Vault-tracked admin password for Frigate's built-in auth. Terraform is
# the source of truth — `random_password.frigate_admin` -> Vault -> CSI
# -> synced k8s secret -> seed-admin-user init -> /config/frigate.db.
#
# Retrieval:
#   vault kv get -field=admin_password secret/frigate/config
#
# Rotation:
#   ./terraform.sh services apply -replace=random_password.frigate_admin
#   (Vault picks up the new value, Reloader rolls the pod, the init
#   container upserts the new PBKDF2 hash into Frigate's user table.)
#
# Frigate has no upstream CLI/env hook for password seeding, so the init
# container talks to its SQLite db directly. See seed-admin-user in
# frigate.tf for the schema-aware seeding script. UI password changes are
# NOT supported — they'd be overwritten on the next pod restart.
resource "random_password" "frigate_admin" {
  length  = 32
  special = false
}

resource "vault_kv_secret_v2" "frigate_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "frigate/config"
  data_json = jsonencode({
    admin_password = random_password.frigate_admin.result
  })
}

module "frigate-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.frigate_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "vault_kv_secret_v2" "frigate_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "frigate/tls"
  data_json = jsonencode({
    fullchain_pem = module.frigate-tls.fullchain_pem
    privkey_pem   = module.frigate-tls.privkey_pem
  })

  # tls-rotator (services/tls-rotator.tf) owns rotation post-bootstrap.
  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "vault_policy" "frigate" {
  name = "frigate-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/frigate/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "frigate" {
  backend                          = "kubernetes"
  role_name                        = "frigate"
  bound_service_account_names      = ["frigate"]
  bound_service_account_namespaces = ["frigate"]
  token_policies                   = [vault_policy.frigate.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "frigate_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-frigate"
      namespace = kubernetes_namespace.frigate.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "frigate-secrets"
          type       = "Opaque"
          data = [
            {
              objectName = "admin_password"
              key        = "admin_password"
            }
          ]
        },
        {
          secretName = "frigate-tls"
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
        roleName     = "frigate"
        objects = yamlencode([
          {
            objectName = "admin_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/frigate/config"
            secretKey  = "admin_password"
          },
          {
            objectName = "tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/frigate/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/frigate/tls"
            secretKey  = "privkey_pem"
          }
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.frigate,
    vault_kubernetes_auth_backend_role.frigate,
    vault_kv_secret_v2.frigate_config,
    vault_kv_secret_v2.frigate_tls,
    vault_policy.frigate
  ]
}
