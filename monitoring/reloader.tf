resource "kubernetes_service_account" "reloader" {
  metadata {
    name      = "reloader"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { app = "reloader" }
  }
}

resource "kubernetes_cluster_role" "reloader" {
  metadata {
    name   = "reloader"
    labels = { app = "reloader" }
  }

  rule {
    api_groups = [""]
    resources  = ["configmaps", "secrets"]
    verbs      = ["list", "get", "watch"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "daemonsets", "statefulsets"]
    verbs      = ["list", "get", "update", "patch"]
  }

  rule {
    api_groups = ["extensions"]
    resources  = ["deployments", "daemonsets"]
    verbs      = ["list", "get", "update", "patch"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = ["list", "get", "update", "patch"]
  }

  rule {
    api_groups = ["argoproj.io"]
    resources  = ["rollouts"]
    verbs      = ["list", "get", "update", "patch"]
  }

  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["create", "patch"]
  }

  rule {
    api_groups = ["coordination.k8s.io"]
    resources  = ["leases"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_cluster_role_binding" "reloader" {
  metadata {
    name   = "reloader"
    labels = { app = "reloader" }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.reloader.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.reloader.metadata[0].name
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
}

resource "kubernetes_deployment" "reloader" {
  metadata {
    name      = "reloader"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { app = "reloader" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "reloader" }
    }

    template {
      metadata {
        labels = { app = "reloader" }
      }

      spec {
        service_account_name = kubernetes_service_account.reloader.metadata[0].name

        container {
          name  = "reloader"
          image = var.image_reloader

          args = [
            "--log-level=info",
            "--reload-strategy=annotations",
          ]

          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "100m", memory = "128Mi" }
          }

          security_context {
            run_as_non_root            = true
            run_as_user                = 65532
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
        }
      }
    }
  }
}
