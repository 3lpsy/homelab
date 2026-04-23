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

    # Satisfies k3s CoreDNS's `import /etc/coredns/custom/*.override` glob so
    # it stops emitting `[WARNING] No files matching import glob pattern` on
    # every reload. Empty file is a no-op import.
    "empty.override" = ""
  }
}
