# NetworkPolicies for the `registry-proxy` namespace.
#
# Reach paths:
#   - Kubelet image pulls — via the K3s node's Tailscale interface
#     (`registry-{dockerio,ghcrio}.MAGIC_DOMAIN` resolves through
#     systemd-resolved → tailscale0). Host-LOCAL source bypasses
#     NetworkPolicy structurally, so no in-cluster ingress rule is needed.
#   - BuildKit Jobs in the `builder` namespace pull through these proxies
#     for `FROM docker.io/...` / `FROM ghcr.io/...` lookups via
#     host_aliases mapping the FQDNs to the registry-dockerio /
#     registry-ghcrio Service ClusterIPs. TCP 443 ingress allowed below.
#   - Egress: each Distribution proxy reaches its upstream
#     (registry-1.docker.io / ghcr.io) via exitnode-haproxy:8888 (set as
#     HTTPS_PROXY in registry-proxy.tf), which load-balances across the
#     ProtonVPN exit-node tinyproxies.

module "registry_proxy_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.registry_proxy.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

resource "kubernetes_network_policy" "registry_proxy_to_exitnode" {
  metadata {
    name      = "registry-proxy-to-exitnode"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }

  spec {
    pod_selector {}
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

# Cross-ns ingress: builder → registry-proxy:443 (image pull-through for
# BuildKit's docker.io / ghcr.io mirrors). Mirror egress lives in
# services/builder-network.tf.
resource "kubernetes_network_policy" "registry_proxy_from_builder" {
  metadata {
    name      = "registry-proxy-from-builder"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }

  spec {
    pod_selector {}
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

