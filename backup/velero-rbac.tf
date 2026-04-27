# Velero needs broad cluster read/list to back up every API object across
# namespaces. Upstream's `velero install` uses cluster-admin via
# ClusterRoleBinding; we follow that. Tighter ClusterRoles exist (velero-rw)
# but require maintaining a per-Kind allowlist that Velero's verb expectations
# routinely outgrow on minor version bumps. Cluster-admin is the supported
# default.

resource "kubernetes_service_account" "velero" {
  metadata {
    name      = "velero"
    namespace = kubernetes_namespace.velero.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "velero"
      component                = "velero"
    }
  }
}

resource "kubernetes_cluster_role_binding" "velero" {
  metadata {
    name = "velero"
    labels = {
      "app.kubernetes.io/name" = "velero"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.velero.metadata[0].name
    namespace = kubernetes_namespace.velero.metadata[0].name
  }
}

# In-namespace read of the cloud-credentials Secret. Required so the server
# pod can resolve the Secret on startup even before the volume is mounted
# (used by some health checks).
resource "kubernetes_role" "velero" {
  metadata {
    name      = "velero"
    namespace = kubernetes_namespace.velero.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding" "velero" {
  metadata {
    name      = "velero"
    namespace = kubernetes_namespace.velero.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.velero.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.velero.metadata[0].name
    namespace = kubernetes_namespace.velero.metadata[0].name
  }
}
