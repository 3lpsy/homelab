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

# Ingress from registry-dockerio ns on :8888. The Distribution registry pulls
# from registry-1.docker.io through the rotator (HTTPS_PROXY env on the
# registry-dockerio container) so docker.io's per-IP anon rate limit doesn't
# bottleneck the whole cluster. Future sibling mirrors (registry-quayio etc.)
# don't need this — only the docker.io mirror is rate-limit-prone.
resource "kubernetes_network_policy" "exitnode_from_registry_dockerio" {
  metadata {
    name      = "exitnode-from-registry-dockerio"
    namespace = kubernetes_namespace.exitnode.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.registry_dockerio.metadata[0].name
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