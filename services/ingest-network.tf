# NetworkPolicies for the `ingest` namespace.
#
# Hosts: syncthing (tailnet ingress), ingest-ui (tailnet ingress + internal
# pull endpoint exposed via ingest-ui-internal Service).
#
# Cross-namespace flows:
#   - Ingress from `navidrome` ns on :443 (selector app=ingest-ui).
#     navidrome-ingest pulls dropzone files via /internal/* over TLS.
#   - Egress to `exitnode` ns on :8888 (selector app=ingest-ui).
#     ingest-ui's yt-dlp invocation routes through a randomly chosen
#     exitnode tinyproxy.

module "ingest_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.ingest.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

# navidrome-ingest pulls dropzone files via TLS to ingest-ui's internal
# Service. Source-side egress allow lives in services/navidrome-ingest-network.tf.
resource "kubernetes_network_policy" "ingest_ui_from_navidrome_ingest" {
  metadata {
    name      = "ingest-ui-from-navidrome-ingest"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }

  spec {
    pod_selector { match_labels = { app = "ingest-ui" } }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.navidrome.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "navidrome-ingest" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

# yt-dlp egress from ingest-ui through the exit-node tinyproxy services.
resource "kubernetes_network_policy" "ingest_ui_to_exitnode" {
  metadata {
    name      = "ingest-ui-to-exitnode"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }

  spec {
    pod_selector { match_labels = { app = "ingest-ui" } }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.exitnode.metadata[0].name
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "8888"
      }
    }
  }
}
