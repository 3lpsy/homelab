resource "kubernetes_namespace" "mcp" {
  metadata {
    name = "mcp"
  }
}

resource "kubernetes_service_account" "mcp" {
  metadata {
    name      = "mcp"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }
  # tailscale sidecar needs k8s API access for the state secret
  automount_service_account_token = true
}

locals {
  # mcp-shared is the external fronting pod (TLS + routing) and the only
  # remaining MCP pod with a tailscale sidecar. mcp-litellm + mcp-searxng
  # used to keep their own sidecars for egress to upstream tailnet FQDNs;
  # they now rely on host_aliases pinning the FQDNs to in-cluster Service
  # ClusterIPs (the cert is the same FQDN cert nginx serves), so no
  # tailnet round-trip is needed.
  mcp_server_names = [
    "mcp-shared",
  ]
}
