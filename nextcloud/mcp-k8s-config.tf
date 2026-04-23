# containers/kubernetes-mcp-server TOML config — mounted into the upstream
# pod as /etc/mcp/config.toml. Defense in depth: read-only, allowlisted tool
# names, denied resource kinds. Namespace allowlisting is enforced by RBAC
# (see mcp-k8s-rbac.tf), not by config — this file is a hint to the binary;
# the K8s API is the actual gate.

resource "kubernetes_config_map" "mcp_k8s_config" {
  metadata {
    name      = "mcp-k8s-config"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }

  data = {
    "config.toml" = <<-EOT
      log_level = 2
      read_only = true
      toolsets = ["core"]

      # Explicit per-tool allowlist on top of read_only — caller can hit only
      # these. pods_get returns full spec+status (kubectl-describe equivalent),
      # pods_log streams container logs, pods_top is metrics, events_list is
      # diagnostic context. No pods_list — RBAC on `list` is namespace-scoped,
      # so omitting the tool prevents callers from enumerating pods at all.
      enabled_tools = ["pods_get", "pods_log", "pods_top", "events_list"]

      cluster_provider_strategy = "in-cluster"
      port = "8080"

      # Block sensitive resource kinds even where RBAC might allow them.
      [[denied_resources]]
      group = ""
      version = "v1"
      kind = "Secret"

      [[denied_resources]]
      group = ""
      version = "v1"
      kind = "ConfigMap"

      [[denied_resources]]
      group = "rbac.authorization.k8s.io"
      version = "v1"
      kind = "Role"

      [[denied_resources]]
      group = "rbac.authorization.k8s.io"
      version = "v1"
      kind = "ClusterRole"

      [[denied_resources]]
      group = "rbac.authorization.k8s.io"
      version = "v1"
      kind = "RoleBinding"

      [[denied_resources]]
      group = "rbac.authorization.k8s.io"
      version = "v1"
      kind = "ClusterRoleBinding"

      [http]
      read_header_timeout = "10s"
      max_body_bytes = 1048576
      rate_limit_rps = 5
      rate_limit_burst = 10
      EOT
  }
}
