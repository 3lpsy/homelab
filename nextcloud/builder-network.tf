# NetworkPolicies for the `builder` namespace.
#
# BuildKit Jobs need:
#   - Internet egress for `FROM` pulls in Dockerfiles (docker.io, ghcr.io,
#     pip/dnf/apt mirrors) — covered by the baseline's internet egress.
#   - Tailscale to reach `registry.MAGIC_DOMAIN` — also covered by the
#     baseline's internet egress (Headscale + DERP).
#   - K8s API for the Tailscale sidecar's TS_KUBE_SECRET — covered.
#
# After the deferred CoreDNS rewrite for `registry.MAGIC_DOMAIN`, BuildKit
# pods will resolve to the registry's ClusterIP and need an explicit
# cross-namespace egress allow. Adding it now is harmless.

module "builder_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.builder.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

# Cross-namespace egress: builder → registry:443 (image push targets).
resource "kubernetes_network_policy" "builder_to_registry" {
  metadata {
    name      = "builder-to-registry"
    namespace = kubernetes_namespace.builder.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.registry.metadata[0].name
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
