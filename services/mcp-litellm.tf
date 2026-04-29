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

module "mcp_litellm_build" {
  source = "./../templates/buildkit-job"

  name      = "mcp-litellm"
  image_ref = local.mcp_litellm_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/mcp-litellm/Dockerfile")
    "server.py"  = file("${path.module}/../data/images/mcp-litellm/server.py")
  }
  context_dirs = local.mcp_common_files

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}

module "mcp_litellm" {
  source = "../templates/mcp-server"

  name                         = "mcp-litellm"
  namespace                    = kubernetes_namespace.mcp.metadata[0].name
  image                        = local.mcp_litellm_image
  build_job_name               = module.mcp_litellm_build.job_name
  service_account_name         = kubernetes_service_account.mcp.metadata[0].name
  image_pull_secret_name       = kubernetes_secret.mcp_registry_pull_secret.metadata[0].name
  shared_secret_provider_class = kubernetes_manifest.mcp_shared_secret_provider.manifest.metadata.name
  log_level                    = var.mcp_litellm_log_level
  image_busybox                = var.image_busybox

  # Pin litellm.<hs>.<magic> to the litellm Service ClusterIP so the
  # backend can dial the FQDN (LITELLM_BASE_URL) and keep using the
  # FQDN-valid TLS cert nginx serves at :443 — no tailnet round-trip.
  host_aliases = [
    {
      ip        = kubernetes_service.litellm.spec[0].cluster_ip
      hostnames = ["${var.litellm_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"]
    },
  ]

  extra_csi_volumes = [
    {
      name                       = "litellm-secrets-store"
      secret_provider_class_name = kubernetes_manifest.mcp_litellm_secret_provider.manifest.metadata.name
      mount_path                 = "/mnt/secrets-litellm"
    },
  ]

  extra_secret_waits = [
    {
      secret_file     = "mcp_litellm_key_hash_map"
      csi_volume_name = "litellm-secrets-store"
    },
  ]

  extra_reload_secrets = ["mcp-litellm-secrets"]

  extra_env = [
    {
      name  = "LITELLM_BASE_URL"
      value = "https://${var.litellm_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
    },
    { name = "MCP_UPSTREAM_TIMEOUT", value = tostring(var.mcp_litellm_upstream_timeout) },
    { name = "MCP_MAX_LOGS", value = tostring(var.mcp_litellm_max_logs) },
    {
      name              = "MCP_KEY_HASH_MAP"
      value_from_secret = { name = "mcp-litellm-secrets", key = "key_hash_map_json" }
    },
    {
      name              = "LITELLM_MASTER_KEY"
      value_from_secret = { name = "mcp-litellm-secrets", key = "master_key" }
    },
  ]
}
