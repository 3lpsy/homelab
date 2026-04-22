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
  # mcp-shared is the external fronting pod (TLS + routing).
  # mcp-searxng keeps its own tailscale sidecar for egress to searxng.<hs>.
  mcp_server_names = [
    "mcp-shared",
    "mcp-searxng",
  ]
}
