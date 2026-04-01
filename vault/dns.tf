# Overrides tailscale DNS to resolve on host
resource "kubernetes_config_map" "coredns_tailscale_node_override" {
  metadata {
    name      = "coredns-custom" # DO not rename
    namespace = "kube-system"
  }
  data = {
    "${var.headscale_subdomain}-${replace(var.headscale_magic_domain, ".", "-")}.server" = <<-EOT
      ${var.headscale_subdomain}.${var.headscale_magic_domain}:53 {
        errors
        cache 30
        forward . 100.100.100.100
      }
    EOT
  }
}
