# NetworkPolicies for the `kube-state-metrics` namespace.
#
# Single deployment exposing :8080 with k8s object state metrics.
#
# Cross-namespace flows this file owns:
#   - ingress prometheus (prometheus ns) → kube-state-metrics :8080 (scrape)

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
