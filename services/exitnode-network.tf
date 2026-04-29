# NetworkPolicies for the `exitnode` namespace.
#
# Hosts one Deployment per WireGuard config (WireGuard client + tinyproxy
# sidecar), each exposed as `exitnode-<name>-proxy.exitnode.svc.cluster.local:8888`.
#
# Cross-namespace flows:
#   - Ingress from `searxng` ns on :8888 (searxng-ranker probes + SearXNG
#     per-engine outgoing proxy) — declared on the searxng side in
#     searxng-network.tf.
#   - Egress to ProtonVPN endpoints over UDP (covered by baseline
#     internet egress; WireGuard handshake is on whatever port the
#     `Endpoint` config specifies, typically UDP 51820 or similar).

module "exitnode_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.exitnode.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

# Ingress from searxng ns on :8888 (mirror of searxng-network.tf egress).
resource "kubernetes_network_policy" "exitnode_from_searxng" {
  metadata {
    name      = "exitnode-from-searxng"
    namespace = kubernetes_namespace.exitnode.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.searxng.metadata[0].name
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

# Ingress from registry-proxy ns on :8888. The combined pull-through cache
# pod (Distribution proxies for docker.io + ghcr.io) routes upstream pulls
# through the rotator (HTTPS_PROXY env on each registry-* container) so
# the per-IP anon rate limit on docker.io doesn't bottleneck the cluster.
resource "kubernetes_network_policy" "exitnode_from_registry_proxy" {
  metadata {
    name      = "exitnode-from-registry-proxy"
    namespace = kubernetes_namespace.exitnode.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.registry_proxy.metadata[0].name
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