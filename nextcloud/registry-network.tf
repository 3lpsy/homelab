# NetworkPolicies for the `registry` namespace.
#
# The Registry is reached two ways today:
#   - Kubelet image pulls — via the host's Tailscale interface
#     (`registry.MAGIC_DOMAIN` resolves through systemd-resolved →
#     tailscale0). Host-LOCAL source bypasses NetworkPolicy structurally,
#     so no rule needed.
#   - BuildKit Jobs in `builder` ns — push images via tailnet today; once
#     the deferred CoreDNS rewrite collapses to ClusterIP, this allow is
#     load-bearing.

module "registry_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.registry.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

# Cross-namespace ingress: builder → registry on 443.
resource "kubernetes_network_policy" "registry_from_builder" {
  metadata {
    name      = "registry-from-builder"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "registry"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.builder.metadata[0].name
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
