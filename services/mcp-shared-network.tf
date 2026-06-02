# NetworkPolicies for the `mcp` namespace.
#
# The namespace hosts mcp-shared (nginx gateway) and per-MCP backend pods
# (mcp-filesystem, mcp-memory, mcp-prometheus, mcp-k8s, mcp-litellm,
# mcp-searxng, mcp-time). External MCP traffic enters via mcp-shared's
# Tailscale sidecar (NetPol-invisible); mcp-shared then routes
# intra-namespace to backends on :8000.
#
# Per-MCP cross-namespace allows live in their own `<svc>-network.tf` files:
#   - mcp-prometheus-network.tf — egress to monitoring:9090 (Prom upstream)
#   - mcp-k8s-network.tf — kube API allow is in baseline; no cross-ns needed
#   - mcp-litellm / mcp-searxng — today reach upstreams via their own TS
#     sidecars (NetPol-invisible); after the deferred CoreDNS rewrites,
#     they'll need cross-ns allows in their respective files.

module "mcp_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.mcp.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

# Cross-ns ingress: opencode → mcp-shared:443. opencode reaches the
# shared MCP gateway via host_aliases pinning mcp-shared.<hs>.<magic> to
# the mcp-shared Service ClusterIP (per feedback_no_egress_only_ts_sidecars).
# Source-side egress allow lives in services/opencode-network.tf as
# opencode-to-mcp-shared.
resource "kubernetes_network_policy" "mcp_shared_from_opencode" {
  metadata {
    name      = "mcp-shared-from-opencode"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }

  spec {
    pod_selector { match_labels = { app = "mcp-shared" } }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.opencode.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "opencode" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}
