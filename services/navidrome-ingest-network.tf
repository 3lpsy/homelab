# NetworkPolicies for navidrome-ingest (in the `navidrome` namespace).
# Internal-only worker — no tailscale sidecar, no public ingress. The
# baseline already allows DNS + intra-namespace + internet egress; the
# litellm/ingest Service ClusterIPs are in the service CIDR (excluded
# from the baseline ipBlock) so we need explicit cross-ns egress rules.

resource "kubernetes_network_policy" "navidrome_ingest_to_litellm" {
  metadata {
    name      = "navidrome-ingest-to-litellm"
    namespace = kubernetes_namespace.navidrome.metadata[0].name
  }

  spec {
    pod_selector { match_labels = { app = "navidrome-ingest" } }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.litellm.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "litellm" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

# Egress to ingest-ui's internal Service (TLS). Pulls dropzone files
# every POLL_INTERVAL seconds.
resource "kubernetes_network_policy" "navidrome_ingest_to_ingest_ui" {
  metadata {
    name      = "navidrome-ingest-to-ingest-ui"
    namespace = kubernetes_namespace.navidrome.metadata[0].name
  }

  spec {
    pod_selector { match_labels = { app = "navidrome-ingest" } }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.ingest.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "ingest-ui" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}
