# NetworkPolicies for the `otel-collector` namespace.
#
# DaemonSet on the K3s node. Reads pod logs from /var/log/pods (host
# volume) and the systemd journal (host volume) — neither traverses the
# pod network. Only data-plane traffic is OTLP ingest to OpenObserve.
#
# Cross-namespace flows this file owns:
#   - egress otel-collector → openobserve (openobserve ns) :5080 (OTLP)

module "otel_collector_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace             = kubernetes_namespace.otel_collector.metadata[0].name
  pod_cidr              = var.k8s_pod_cidr
  service_cidr          = var.k8s_service_cidr
  allow_internet_egress = false
  # kubelet metadata enrichment uses the in-cluster K8s API.
  allow_kube_api_egress = true
}

# Cross-ns egress: otel-collector → openobserve :5080 (OTLP/HTTP).
# Mirror ingress lives in services/monitoring-network.tf as
# openobserve-from-otel-collector.
resource "kubernetes_network_policy" "otel_collector_to_openobserve" {
  metadata {
    name      = "otel-collector-to-openobserve"
    namespace = kubernetes_namespace.otel_collector.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { app = "otel-collector" }
    }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.openobserve.metadata[0].name
          }
        }
        pod_selector {
          match_labels = { app = "openobserve" }
        }
      }
      ports {
        protocol = "TCP"
        port     = "5080"
      }
    }
  }
}
