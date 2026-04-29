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
# `list` on pods is namespace-wide within each allowed namespace — bearer
# holders can enumerate every pod there. Acceptable because get/log/top
# already span the same set.

resource "kubernetes_role" "mcp_k8s_reader" {
  for_each = toset(var.mcp_k8s_allowed_namespaces)

  metadata {
    name      = "mcp-k8s-reader"
    namespace = each.value
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list"]
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

  # Make the Role wait until every namespace this deployment owns has been
  # created. The for_each list is a static set of strings, so terraform
  # would otherwise plan Role creation in parallel with kubernetes_namespace
  # creation and fail with "namespaces not found" on a fresh apply
  # (https://github.com/hashicorp/terraform-provider-kubernetes/issues/1380).
  # Built-in namespaces (default, kube-system) and namespaces from other
  # deployments (monitoring) are not in this list — they exist by the time
  # this deployment runs.
  depends_on = [
    kubernetes_namespace.builder,
    kubernetes_namespace.exitnode,
    kubernetes_namespace.frigate,
    kubernetes_namespace.homeassist,
    kubernetes_namespace.litellm,
    kubernetes_namespace.mcp,
    kubernetes_namespace.navidrome,
    kubernetes_namespace.nextcloud,
    kubernetes_namespace.pihole,
    kubernetes_namespace.radicale,
    kubernetes_namespace.registry,
    kubernetes_namespace.registry_proxy,
    kubernetes_namespace.searxng,
    kubernetes_namespace.thunderbolt,
    kubernetes_namespace.tls_rotator,
  ]
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

  # Same dependency rationale as kubernetes_role.mcp_k8s_reader above —
  # the binding lives in the target namespace and would race namespace
  # creation otherwise.
  depends_on = [
    kubernetes_namespace.builder,
    kubernetes_namespace.exitnode,
    kubernetes_namespace.frigate,
    kubernetes_namespace.homeassist,
    kubernetes_namespace.litellm,
    kubernetes_namespace.mcp,
    kubernetes_namespace.navidrome,
    kubernetes_namespace.nextcloud,
    kubernetes_namespace.pihole,
    kubernetes_namespace.radicale,
    kubernetes_namespace.registry,
    kubernetes_namespace.registry_proxy,
    kubernetes_namespace.searxng,
    kubernetes_namespace.thunderbolt,
    kubernetes_namespace.tls_rotator,
  ]
}

# BuildKit job — builds the Python MCP server image. Replaces the previous
# pair of jobs (upstream Go mirror + auth-gate sidecar) with a single Python
# image that bundles the auth middleware. See templates/buildkit-job.

module "mcp_k8s_build" {
  source = "./../templates/buildkit-job"

  name      = "mcp-k8s"
  image_ref = local.mcp_k8s_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/mcp-k8s/Dockerfile")
    "server.py"  = file("${path.module}/../data/images/mcp-k8s/server.py")
  }

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}

module "mcp_k8s" {
  source = "../templates/mcp-server"

  name                         = "mcp-k8s"
  namespace                    = kubernetes_namespace.mcp.metadata[0].name
  image                        = local.mcp_k8s_image
  build_job_name               = module.mcp_k8s_build.job_name
  service_account_name         = kubernetes_service_account.mcp_k8s.metadata[0].name
  image_pull_secret_name       = kubernetes_secret.mcp_registry_pull_secret.metadata[0].name
  shared_secret_provider_class = kubernetes_manifest.mcp_shared_secret_provider.manifest.metadata.name
  log_level                    = var.mcp_k8s_log_level
  image_busybox                = var.image_busybox

  # No data PVC, but the CSI secrets-store mount currently relies on the
  # pod-level fs_group for group read.
  pod_fs_group = 1000

  extra_env = [
    {
      name  = "MCP_K8S_ALLOWED_NAMESPACES"
      value = join(",", var.mcp_k8s_allowed_namespaces)
    },
  ]
}
