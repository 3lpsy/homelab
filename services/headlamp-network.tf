# NetworkPolicies for the `headlamp` namespace.
#
# Single-pod namespace (headlamp + nginx + tailscale sidecars). Cross-ns
# flows this file owns:
#   - egress  headlamp → oidc:443 (OIDC sign-in)
#   - egress  headlamp → kube-apiserver:6443 (covered by netpol-baseline
#             allow_kube_api_egress; Headlamp uses its SA token to talk
#             to kubernetes.default.svc which kube-proxy DNATs to host:6443)

module "headlamp_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.headlamp.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
  # Tailscale sidecar reaches Headscale + DERP; oauth2 token exchange
  # against Zitadel goes via host_aliases (cross-ns, allowed below).
  allow_internet_egress = true
  # Headlamp talks to kube-apiserver on every page load; tailscale
  # sidecar also persists state to a k8s Secret via TS_KUBE_SECRET.
  allow_kube_api_egress = true
}

# Cross-ns egress: headlamp → oidc:443 for the OIDC sign-in flow against
# Zitadel. Mirror ingress lives in services/zitadel-network.tf as
# oidc-from-headlamp.
resource "kubernetes_network_policy" "headlamp_to_oidc" {
  metadata {
    name      = "headlamp-to-oidc"
    namespace = kubernetes_namespace.headlamp.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { app = "headlamp" }
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
