# NetworkPolicies for the `builder` namespace.
#
# BuildKit Jobs need:
#   - Internet egress for `FROM` pulls in Dockerfiles (docker.io, ghcr.io,
#     pip/dnf/apt mirrors) — covered by the baseline's internet egress.
#   - Cross-ns egress to `registry/registry:443` (push target) and
#     `registry-proxy/registry-{dockerio,ghcrio}:443` (pull-through caches
#     used by buildkitd's mirrors). Allowed below.
#
# Each Job pod uses host_aliases to map `registry.<hs>.<magic>`,
# `registry-dockerio.<hs>.<magic>`, and `registry-ghcrio.<hs>.<magic>` to
# the corresponding Service ClusterIPs (Phase B4 of the egress-only
# Tailscale sidecar removal). nginx terminates TLS in each registry pod
# with the matching FQDN cert.

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

# Cross-namespace egress: builder → registry-proxy:443 (image pull-through
# for `FROM docker.io/...` and `FROM ghcr.io/...` via the buildkitd
# config-rendered mirrors). Mirror ingress lives in
# nextcloud/registry-proxy-network.tf.
resource "kubernetes_network_policy" "builder_to_registry_proxy" {
  metadata {
    name      = "builder-to-registry-proxy"
    namespace = kubernetes_namespace.builder.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.registry_proxy.metadata[0].name
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

