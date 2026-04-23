# Dedicated SA for the upstream kubernetes-mcp-server. Kept distinct from the
# shared `mcp` SA because this one binds to RBAC inside *other* namespaces —
# scope creep on the shared SA would broaden unrelated MCPs.

resource "kubernetes_service_account" "mcp_k8s" {
  metadata {
    name      = "mcp-k8s"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }
  # Required: the upstream binary uses in-cluster config (the auto-mounted SA
  # token) to call the K8s API.
  automount_service_account_token = true
}

# Per-allowed-namespace Role + RoleBinding. Namespace-scoped on purpose:
# avoids a cluster-wide ClusterRoleBinding, and revoking access to a namespace
# is a `terraform destroy` of one for_each entry.
#
# RBAC nuance: `resourceNames` is honoured on `get` but NOT on `list` / `watch`.
# Since enabled_tools omits pods_list, this Role grants only `get` on pods and
# pods/log — the upstream tool surface lines up with the RBAC verb set.

resource "kubernetes_role" "mcp_k8s_reader" {
  for_each = toset(var.mcp_k8s_allowed_namespaces)

  metadata {
    name      = "mcp-k8s-reader"
    namespace = each.value
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get"]
  }

  # events_list backs the events_list tool. Events are inherently bulk-readable
  # (no resourceNames support); they don't carry secret payloads.
  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["get", "list", "watch"]
  }
}

# Metrics ClusterRole — cluster-scope because the upstream pods_top tool
# defaults to all_namespaces=true and metrics-server's list endpoint can't be
# narrowed by namespace (an agent calling all_namespaces=true issues a single
# cluster-LIST). metrics.k8s.io payloads are CPU/memory numbers with no
# secret material, so cluster-wide read is acceptable even when actual pods
# / logs stay namespace-scoped via the Role above.
resource "kubernetes_cluster_role" "mcp_k8s_metrics_reader" {
  metadata {
    name = "mcp-k8s-metrics-reader"
  }

  rule {
    api_groups = ["metrics.k8s.io"]
    resources  = ["pods"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role_binding" "mcp_k8s_metrics_reader" {
  metadata {
    name = "mcp-k8s-metrics-reader"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.mcp_k8s_metrics_reader.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.mcp_k8s.metadata[0].name
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }
}

resource "kubernetes_role_binding" "mcp_k8s_reader" {
  for_each = toset(var.mcp_k8s_allowed_namespaces)

  metadata {
    name      = "mcp-k8s-reader"
    namespace = each.value
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.mcp_k8s_reader[each.value].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.mcp_k8s.metadata[0].name
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }
}
