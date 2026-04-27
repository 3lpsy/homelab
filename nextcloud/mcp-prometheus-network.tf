# Cross-namespace egress for mcp-prometheus → Prometheus in monitoring ns.
#
# mcp-prometheus is configured via `var.mcp_prometheus_url` to reach
# `http://prometheus.monitoring.svc.cluster.local:9090` directly (in-cluster
# DNS, no Tailscale hop). This allow is load-bearing today, not deferred.

resource "kubernetes_network_policy" "mcp_prometheus_to_monitoring" {
  metadata {
    name      = "mcp-prometheus-to-monitoring"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "mcp-prometheus"
      }
    }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "monitoring"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "9090"
      }
    }
  }
}
