resource "kubernetes_service_account" "kube_state_metrics" {
  metadata {
    name      = "kube-state-metrics"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
}

resource "kubernetes_cluster_role" "kube_state_metrics" {
  metadata { name = "kube-state-metrics" }

  rule {
    api_groups = [""]
    resources = [
      "nodes", "pods", "services", "endpoints",
      "persistentvolumeclaims", "persistentvolumes",
      "configmaps", "secrets", "namespaces",
      "resourcequotas", "replicationcontrollers",
      "limitranges",
    ]
    verbs = ["list", "watch"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "daemonsets", "replicasets", "statefulsets"]
    verbs      = ["list", "watch"]
  }
  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = ["list", "watch"]
  }
  rule {
    api_groups = ["autoscaling"]
    resources  = ["horizontalpodautoscalers"]
    verbs      = ["list", "watch"]
  }
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses", "networkpolicies"]
    verbs      = ["list", "watch"]
  }
  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses", "volumeattachments"]
    verbs      = ["list", "watch"]
  }
  rule {
    api_groups = ["coordination.k8s.io"]
    resources  = ["leases"]
    verbs      = ["list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "kube_state_metrics" {
  metadata { name = "kube-state-metrics" }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.kube_state_metrics.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.kube_state_metrics.metadata[0].name
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
}

resource "kubernetes_deployment" "kube_state_metrics" {
  metadata {
    name      = "kube-state-metrics"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "kube-state-metrics" }
    }

    template {
      metadata {
        labels = { app = "kube-state-metrics" }
      }

      spec {
        service_account_name            = kubernetes_service_account.kube_state_metrics.metadata[0].name
        automount_service_account_token = true

        container {
          name  = "kube-state-metrics"
          image = "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.13.0"

          port {
            container_port = 8080
            name           = "metrics"
          }
          port {
            container_port = 8081
            name           = "telemetry"
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "250m", memory = "256Mi" }
          }

          liveness_probe {
            http_get {
              path = "/livez"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/readyz"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "kube_state_metrics" {
  metadata {
    name      = "kube-state-metrics"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    selector = { app = "kube-state-metrics" }

    port {
      name        = "metrics"
      port        = 8080
      target_port = 8080
    }
    port {
      name        = "telemetry"
      port        = 8081
      target_port = 8081
    }
  }
}
