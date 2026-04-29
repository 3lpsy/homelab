# NetworkPolicies for the `thunderbolt` namespace.
#
# Hosts: thunderbolt-backend, thunderbolt-frontend (nginx), keycloak,
# postgres, mongo, powersync. All cross-pod traffic is intra-namespace
# today (backend ↔ keycloak, backend ↔ mongo, powersync ↔ postgres).
#
# thunderbolt-backend reaches `searxng.<hs>.<magic>` and
# `litellm.<hs>.<magic>` via host_aliases mapping the FQDNs to the
# searxng / litellm Service ClusterIPs (egress-only Tailscale sidecar
# was removed). The TCP 443 cross-ns egress allows below are
# load-bearing.

module "thunderbolt_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.thunderbolt.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

# Cross-ns egress: thunderbolt-backend → searxng:443. Mirror ingress lives
# in services/searxng-network.tf.
resource "kubernetes_network_policy" "thunderbolt_to_searxng" {
  metadata {
    name      = "thunderbolt-to-searxng"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  spec {
    pod_selector { match_labels = { app = "thunderbolt-backend" } }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.searxng.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "searxng" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

# Cross-ns egress: thunderbolt-backend → litellm:443. Mirror ingress lives
# in services/litellm-network.tf.
resource "kubernetes_network_policy" "thunderbolt_to_litellm" {
  metadata {
    name      = "thunderbolt-to-litellm"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  spec {
    pod_selector { match_labels = { app = "thunderbolt-backend" } }
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

