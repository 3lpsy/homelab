# mcp-litellm-specific secrets: mirrors LiteLLM's master key from
# kv/litellm/config into kv/mcp/litellm so the shared `mcp` Vault policy
# (already scoped to kv/data/mcp/*) covers it without handing every other
# mcp-* pod access to the master key. Only mcp-litellm's Deployment mounts
# this SPC.

resource "vault_kv_secret_v2" "mcp_litellm" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "mcp/litellm"
  data_json = jsonencode({
    master_key = "sk-${random_password.litellm_master_key.result}"
    # {<mcp_bearer>: [<litellm_key_hash>, ...]} — kept as JSON-in-JSON so the
    # pod can mount it as a single env var via the CSI SPC. Bearers are
    # secret; keeping this map alongside the master key (rather than in the
    # pod spec env) avoids leaking them to anyone with `get pods` rights.
    key_hash_map_json = jsonencode({
      for user, hashes in var.mcp_litellm_key_hashes :
      random_password.mcp_api_keys[user].result => hashes
      if contains(var.mcp_api_key_users, user)
    })
  })
}

resource "kubernetes_manifest" "mcp_litellm_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-mcp-litellm"
      namespace = kubernetes_namespace.mcp.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "mcp-litellm-secrets"
          type       = "Opaque"
          data = [
            { objectName = "mcp_litellm_master_key", key = "master_key" },
            { objectName = "mcp_litellm_key_hash_map", key = "key_hash_map_json" },
          ]
        },
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "mcp"
        objects = yamlencode([
          {
            objectName = "mcp_litellm_master_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/mcp/litellm"
            secretKey  = "master_key"
          },
          {
            objectName = "mcp_litellm_key_hash_map"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/mcp/litellm"
            secretKey  = "key_hash_map_json"
          },
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.mcp,
    vault_kubernetes_auth_backend_role.mcp,
    vault_kv_secret_v2.mcp_litellm,
  ]
}
