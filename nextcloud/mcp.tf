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
  # mcp-searxng and mcp-litellm keep their own tailscale sidecar for egress
  # to the upstream's tailnet FQDN (in-cluster DNS would TLS-fail).
  mcp_server_names = [
    "mcp-shared",
    "mcp-searxng",
    "mcp-prometheus",
    "mcp-litellm",
  ]
}
