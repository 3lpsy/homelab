resource "kubernetes_namespace" "kube_state_metrics" {
  metadata {
    name = "kube-state-metrics"
  }
}

resource "kubernetes_service_account" "kube_state_metrics" {
  metadata {
    name      = "kube-state-metrics"
    namespace = kubernetes_namespace.kube_state_metrics.metadata[0].name
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
  rule {
    api_groups = ["certificates.k8s.io"]
    resources  = ["certificatesigningrequests"]
    verbs      = ["list", "watch"]
  }
  rule {
    api_groups = ["discovery.k8s.io"]
    resources  = ["endpointslices"]
    verbs      = ["list", "watch"]
  }
  rule {
    api_groups = ["admissionregistration.k8s.io"]
    resources  = ["mutatingwebhookconfigurations", "validatingwebhookconfigurations"]
    verbs      = ["list", "watch"]
  }
  rule {
    api_groups = ["policy"]
    resources  = ["poddisruptionbudgets"]
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
    namespace = kubernetes_namespace.kube_state_metrics.metadata[0].name
  }
}

resource "kubernetes_deployment" "kube_state_metrics" {
  metadata {
    name      = "kube-state-metrics"
    namespace = kubernetes_namespace.kube_state_metrics.metadata[0].name
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
          image = var.image_kube_state_metrics
          image_pull_policy = "Always"

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
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "kube_state_metrics" {
  metadata {
    name      = "kube-state-metrics"
    namespace = kubernetes_namespace.kube_state_metrics.metadata[0].name
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

# =============================================================================
# NetworkPolicies for the `kube-state-metrics` namespace.
#
# Single deployment exposing :8080 with k8s object state metrics.
#
# Cross-namespace flows this file owns:
#   - ingress prometheus (prometheus ns) → kube-state-metrics :8080 (scrape)
# =============================================================================

module "kube_state_metrics_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace             = kubernetes_namespace.kube_state_metrics.metadata[0].name
  pod_cidr              = var.k8s_pod_cidr
  service_cidr          = var.k8s_service_cidr
  allow_internet_egress = false
  # ksm reads from the K8s API to populate its metrics surface.
  allow_kube_api_egress = true
}

# Cross-ns ingress: prometheus (prometheus ns) → kube-state-metrics :8080.
# Mirror egress lives in services/prometheus-network.tf as
# prometheus-to-kube-state-metrics.
resource "kubernetes_network_policy" "kube_state_metrics_from_prometheus" {
  metadata {
    name      = "kube-state-metrics-from-prometheus"
    namespace = kubernetes_namespace.kube_state_metrics.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { app = "kube-state-metrics" }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.prometheus.metadata[0].name
          }
        }
        pod_selector {
          match_labels = { app = "prometheus" }
        }
      }
      ports {
        protocol = "TCP"
        port     = "8080"
      }
    }
  }
}
