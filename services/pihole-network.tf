# Cross-ns egress: oauth2-proxy sidecar -> Zitadel for the OIDC code+PKCE
# flow (discovery, JWKS, token exchange, userinfo). Pod-scoped per memory
# feedback_netpol_least_privilege. Mirror ingress lives in
# services/zitadel-network.tf as oidc-from-pihole.
resource "kubernetes_network_policy" "pihole_to_oidc" {
  metadata {
    name      = "pihole-to-oidc"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = { app = "pihole" }
    }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "oidc"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}
