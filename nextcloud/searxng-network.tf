# NetworkPolicies for the `searxng` namespace.
#
# Hosts: searxng (with embedded valkey sidecar) + searxng-ranker daemon.
#
# Cross-namespace flows:
#   - searxng-ranker → kube-API (patches SearXNG ConfigMap) — baseline
#   - searxng-ranker → exitnode-*-proxy.exitnode.svc.cluster.local:8888
#     (probes exit-node proxies for latency/health)
#   - searxng → exitnode-*-proxy.exitnode.svc.cluster.local:8888 (per-engine
#     outgoing proxy chosen from the ranker-rewritten config)

module "searxng_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.searxng.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

resource "kubernetes_network_policy" "searxng_to_exitnode" {
  metadata {
    name      = "searxng-to-exitnode"
    namespace = kubernetes_namespace.searxng.metadata[0].name
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
