# Namespace + shared RBAC

resource "kubernetes_namespace" "thunderbolt" {
  metadata {
    name = "thunderbolt"
  }
}

resource "kubernetes_service_account" "thunderbolt" {
  metadata {
    name      = "thunderbolt"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_secret" "thunderbolt_tailscale_state" {
  for_each = toset([
    "thunderbolt-tailscale-state",
  ])

  metadata {
    name      = each.value
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }
  type = "Opaque"

  lifecycle {
    ignore_changes = [data, type]
  }
}

resource "kubernetes_role" "thunderbolt_tailscale" {
  metadata {
    name      = "thunderbolt-tailscale"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    resource_names = [
      "thunderbolt-tailscale-state",
    ]
    verbs = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "thunderbolt_tailscale" {
  metadata {
    name      = "thunderbolt-tailscale"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.thunderbolt_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.thunderbolt.metadata[0].name
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }
}

# Registry pull secret (reuses the "internal" registry user)

resource "kubernetes_secret" "thunderbolt_registry_pull_secret" {
  metadata {
    name      = "registry-pull-secret"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
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

# Random passwords / secrets

resource "random_password" "thunderbolt_postgres" {
  length  = 32
  special = false
}

resource "random_password" "thunderbolt_powersync_role" {
  length  = 32
  special = false
}

resource "random_password" "thunderbolt_keycloak_db" {
  length  = 32
  special = false
}

resource "random_password" "thunderbolt_keycloak_admin" {
  length  = 24
  special = false
}

resource "random_password" "thunderbolt_seed_user" {
  length  = 24
  special = false
}

resource "random_password" "thunderbolt_better_auth_secret" {
  length  = 48
  special = false
}

resource "random_password" "thunderbolt_oidc_client_secret" {
  length  = 40
  special = false
}

resource "random_password" "thunderbolt_powersync_jwt_secret" {
  length  = 48
  special = false
}

# Headscale preauth

resource "headscale_pre_auth_key" "thunderbolt_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.thunderbolt_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "thunderbolt_tailscale_auth" {
  metadata {
    name      = "thunderbolt-tailscale-auth"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.thunderbolt_server.key
  }
}

# Thunderbolt backend points `/v1/chat/completions` at LiteLLM. The backend
# reads the upstream API key from THUNDERBOLT_INFERENCE_API_KEY. Sharing the
# LiteLLM master key today; swap to a scoped virtual key (created via LiteLLM
# admin UI) once the single-user setup grows.
resource "kubernetes_secret" "thunderbolt_inference" {
  metadata {
    name      = "thunderbolt-inference"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }
  type = "Opaque"
  data = {
    api_key = "sk-${random_password.litellm_master_key.result}"
  }
}

# TLS cert

module "thunderbolt-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = local.thunderbolt_fqdn
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

# Vault KV — config secrets (app-level)

resource "vault_kv_secret_v2" "thunderbolt_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "thunderbolt/config"
  data_json = jsonencode({
    postgres_password        = random_password.thunderbolt_postgres.result
    powersync_role_password  = random_password.thunderbolt_powersync_role.result
    keycloak_db_password     = random_password.thunderbolt_keycloak_db.result
    keycloak_admin_password  = random_password.thunderbolt_keycloak_admin.result
    keycloak_admin_username  = "admin"
    seed_user_password       = random_password.thunderbolt_seed_user.result
    better_auth_secret       = random_password.thunderbolt_better_auth_secret.result
    oidc_client_secret       = random_password.thunderbolt_oidc_client_secret.result
    powersync_jwt_secret     = random_password.thunderbolt_powersync_jwt_secret.result
    powersync_jwt_secret_b64 = base64encode(random_password.thunderbolt_powersync_jwt_secret.result)
    database_url             = "postgresql://postgres:${random_password.thunderbolt_postgres.result}@thunderbolt-postgres:5432/thunderbolt"
    powersync_database_url   = "postgresql://powersync_role:${random_password.thunderbolt_powersync_role.result}@thunderbolt-postgres:5432/thunderbolt"
  })
}

resource "vault_kv_secret_v2" "thunderbolt_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "thunderbolt/tls"
  data_json = jsonencode({
    fullchain_pem = module.thunderbolt-tls.fullchain_pem
    privkey_pem   = module.thunderbolt-tls.privkey_pem
  })

  # tls-rotator (nextcloud/tls-rotator.tf) owns rotation post-bootstrap.
  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "vault_policy" "thunderbolt" {
  name = "thunderbolt-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/thunderbolt/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "thunderbolt" {
  backend                          = "kubernetes"
  role_name                        = "thunderbolt"
  bound_service_account_names      = ["thunderbolt"]
  bound_service_account_namespaces = ["thunderbolt"]
  token_policies                   = [vault_policy.thunderbolt.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "thunderbolt_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-thunderbolt"
      namespace = kubernetes_namespace.thunderbolt.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "thunderbolt-secrets"
          type       = "Opaque"
          data = [
            { objectName = "thunderbolt_postgres_password", key = "postgres_password" },
            { objectName = "thunderbolt_powersync_role_password", key = "powersync_role_password" },
            { objectName = "thunderbolt_keycloak_db_password", key = "keycloak_db_password" },
            { objectName = "thunderbolt_keycloak_admin_password", key = "keycloak_admin_password" },
            { objectName = "thunderbolt_keycloak_admin_username", key = "keycloak_admin_username" },
            { objectName = "thunderbolt_seed_user_password", key = "seed_user_password" },
            { objectName = "thunderbolt_better_auth_secret", key = "better_auth_secret" },
            { objectName = "thunderbolt_oidc_client_secret", key = "oidc_client_secret" },
            { objectName = "thunderbolt_powersync_jwt_secret", key = "powersync_jwt_secret" },
            { objectName = "thunderbolt_powersync_jwt_secret_b64", key = "powersync_jwt_secret_b64" },
            { objectName = "thunderbolt_database_url", key = "database_url" },
            { objectName = "thunderbolt_powersync_database_url", key = "powersync_database_url" },
          ]
        },
        {
          secretName = "thunderbolt-tls"
          type       = "kubernetes.io/tls"
          data = [
            { objectName = "thunderbolt_tls_crt", key = "tls.crt" },
            { objectName = "thunderbolt_tls_key", key = "tls.key" },
          ]
        }
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "thunderbolt"
        objects = yamlencode([
          { objectName = "thunderbolt_postgres_password", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/thunderbolt/config", secretKey = "postgres_password" },
          { objectName = "thunderbolt_powersync_role_password", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/thunderbolt/config", secretKey = "powersync_role_password" },
          { objectName = "thunderbolt_keycloak_db_password", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/thunderbolt/config", secretKey = "keycloak_db_password" },
          { objectName = "thunderbolt_keycloak_admin_password", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/thunderbolt/config", secretKey = "keycloak_admin_password" },
          { objectName = "thunderbolt_keycloak_admin_username", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/thunderbolt/config", secretKey = "keycloak_admin_username" },
          { objectName = "thunderbolt_seed_user_password", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/thunderbolt/config", secretKey = "seed_user_password" },
          { objectName = "thunderbolt_better_auth_secret", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/thunderbolt/config", secretKey = "better_auth_secret" },
          { objectName = "thunderbolt_oidc_client_secret", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/thunderbolt/config", secretKey = "oidc_client_secret" },
          { objectName = "thunderbolt_powersync_jwt_secret", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/thunderbolt/config", secretKey = "powersync_jwt_secret" },
          { objectName = "thunderbolt_powersync_jwt_secret_b64", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/thunderbolt/config", secretKey = "powersync_jwt_secret_b64" },
          { objectName = "thunderbolt_database_url", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/thunderbolt/config", secretKey = "database_url" },
          { objectName = "thunderbolt_powersync_database_url", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/thunderbolt/config", secretKey = "powersync_database_url" },
          { objectName = "thunderbolt_tls_crt", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/thunderbolt/tls", secretKey = "fullchain_pem" },
          { objectName = "thunderbolt_tls_key", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/thunderbolt/tls", secretKey = "privkey_pem" },
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.thunderbolt,
    vault_kubernetes_auth_backend_role.thunderbolt,
    vault_kv_secret_v2.thunderbolt_config,
    vault_kv_secret_v2.thunderbolt_tls,
  ]
}

