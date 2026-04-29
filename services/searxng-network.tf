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

# Cross-ns ingress: thunderbolt-backend → searxng:443. Replaces the
# Tailscale-routed egress that thunderbolt-backend used to do via its
# now-removed sidecar (env SEARXNG_URL). thunderbolt-backend reaches
# searxng.<hs>.<magic> via host_aliases pointing at the searxng Service
# ClusterIP; nginx terminates TLS with the same FQDN-valid cert.
resource "kubernetes_network_policy" "searxng_from_thunderbolt" {
  metadata {
    name      = "searxng-from-thunderbolt"
    namespace = kubernetes_namespace.searxng.metadata[0].name
  }

  spec {
    pod_selector { match_labels = { app = "searxng" } }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.thunderbolt.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "thunderbolt-backend" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

# Cross-ns ingress: mcp-searxng → searxng:443. Replaces the Tailscale-routed
# egress that the mcp-searxng pod used to do via its now-removed sidecar
# (env MCP_SEARXNG_URL). The mcp namespace has no baseline NetworkPolicy so
# no source-side egress allow is needed; this rule is the gate.
resource "kubernetes_network_policy" "searxng_from_mcp_searxng" {
  metadata {
    name      = "searxng-from-mcp-searxng"
    namespace = kubernetes_namespace.searxng.metadata[0].name
  }

  spec {
    pod_selector { match_labels = { app = "searxng" } }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.mcp.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "mcp-searxng" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

