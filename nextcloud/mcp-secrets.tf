resource "kubernetes_role" "mcp_tailscale" {
  metadata {
    name      = "mcp-tailscale"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["create"]
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = [for n in local.mcp_server_names : "${n}-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "mcp_tailscale" {
  metadata {
    name      = "mcp-tailscale"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.mcp_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.mcp.metadata[0].name
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }
}

# Shared API keys — every MCP server in this namespace authenticates callers
# against the same Bearer token set. Per-service SPCs below read this Vault
# secret and materialise a k8s Secret named `<service>-auth` in the mcp ns.

resource "random_password" "mcp_api_keys" {
  for_each = toset(var.mcp_api_key_users)
  length   = 48
  special  = false
}

# Shared tenant-dir salt — every stateful MCP server in this namespace hashes
# API keys through this same salt so a given key maps to one on-disk tenant
# dir across services (e.g. /data/<hash>/memory.jsonl lives beside the
# filesystem server's /data/<hash>/<session_hash>/ tree on the shared PVC).
resource "random_password" "mcp_path_salt" {
  length  = 64
  special = false
}

locals {
  # Sort for determinism — for_each over a set gives unordered iteration, and
  # we don't want the CSV churning across plans.
  mcp_api_keys_csv = join(",", [for u in sort(var.mcp_api_key_users) : random_password.mcp_api_keys[u].result])
}

resource "vault_kv_secret_v2" "mcp_auth" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "mcp/auth"
  data_json = jsonencode(merge(
    {
      api_keys_csv = local.mcp_api_keys_csv
      path_salt    = random_password.mcp_path_salt.result
    },
    { for u, p in random_password.mcp_api_keys : "api_key_${u}" => p.result },
  ))
}

# Headscale preauth — shared across all MCP runtime pods. Each pod sets its own
# TS_HOSTNAME so they register as distinct tailnet nodes under user `mcp_user`.

resource "headscale_pre_auth_key" "mcp" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.mcp_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "mcp_tailscale_auth" {
  metadata {
    name      = "mcp-tailscale-auth"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.mcp.key
  }
}

# Registry pull secret (reuses the "internal" registry user)

resource "kubernetes_secret" "mcp_registry_pull_secret" {
  metadata {
    name      = "registry-pull-secret"
    namespace = kubernetes_namespace.mcp.metadata[0].name
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

# Shared Vault policy — grants read on mcp/* KV paths.
# Per-service TLS / secrets live at mcp/<service>/<kind>.

resource "vault_policy" "mcp" {
  name = "mcp-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/mcp/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "mcp" {
  backend                          = "kubernetes"
  role_name                        = "mcp"
  bound_service_account_names      = ["mcp"]
  bound_service_account_namespaces = ["mcp"]
  token_policies                   = [vault_policy.mcp.name]
  token_ttl                        = 86400
}
