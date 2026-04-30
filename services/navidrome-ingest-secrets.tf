resource "kubernetes_service_account" "navidrome_ingest" {
  metadata {
    name      = "navidrome-ingest"
    namespace = kubernetes_namespace.navidrome.metadata[0].name
  }
  automount_service_account_token = false
}

# In-cluster registry pull secret for navidrome ns. Only navidrome-ingest
# uses a custom image here; navidrome itself pulls from Docker Hub.
resource "kubernetes_secret" "navidrome_ingest_registry_pull_secret" {
  metadata {
    name      = "registry-pull-secret"
    namespace = kubernetes_namespace.navidrome.metadata[0].name
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

# Scoped LiteLLM virtual key for navidrome-ingest. Sourced from
# var.litellm_user_keys["ingestor"] (set out-of-band via .env), mirrored
# into Vault so it follows the same CSI flow as every other secret.
# Empty value is allowed at apply time — the pod boots but LLM calls
# return 401 until populated.
resource "vault_kv_secret_v2" "navidrome_ingest_litellm" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "navidrome-ingest/litellm"
  data_json = jsonencode({
    api_key = lookup(var.litellm_user_keys, "ingestor", "")
  })
}

# navidrome-ingest reads:
#   - its scoped LiteLLM virtual key (NOT the master key)
#   - ingest-ui internal bearer token for pulling dropzone files
resource "vault_policy" "navidrome_ingest" {
  name = "navidrome-ingest-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/navidrome-ingest/litellm" {
  capabilities = ["read"]
}
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/ingest-ui/internal" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "navidrome_ingest" {
  backend                          = "kubernetes"
  role_name                        = "navidrome-ingest"
  bound_service_account_names      = ["navidrome-ingest"]
  bound_service_account_namespaces = ["navidrome"]
  token_policies                   = [vault_policy.navidrome_ingest.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "navidrome_ingest_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-navidrome-ingest"
      namespace = kubernetes_namespace.navidrome.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "navidrome-ingest-secrets"
          type       = "Opaque"
          data = [
            { objectName = "litellm_api_key", key = "litellm_api_key" },
            { objectName = "ingest_internal_token", key = "ingest_internal_token" },
          ]
        },
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "navidrome-ingest"
        objects = yamlencode([
          {
            objectName = "litellm_api_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/navidrome-ingest/litellm"
            secretKey  = "api_key"
          },
          {
            objectName = "ingest_internal_token"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/ingest-ui/internal"
            secretKey  = "token"
          },
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.navidrome,
    vault_kubernetes_auth_backend_role.navidrome_ingest,
    vault_policy.navidrome_ingest,
    vault_kv_secret_v2.navidrome_ingest_litellm,
    vault_kv_secret_v2.ingest_internal,
  ]
}
