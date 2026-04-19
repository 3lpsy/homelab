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
  # Add a new MCP server name here to grant its tailscale sidecar the RBAC
  # needed to manage its state secret (`<name>-tailscale-state`).
  mcp_server_names = [
    "mcp-duckduckgo",
    "mcp-searxng",
  ]
}
