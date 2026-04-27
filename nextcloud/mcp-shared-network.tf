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
