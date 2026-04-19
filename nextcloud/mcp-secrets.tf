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
