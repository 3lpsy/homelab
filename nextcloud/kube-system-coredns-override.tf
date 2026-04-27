# K3s mounts ONE ConfigMap named `coredns-custom` from `kube-system` into
# CoreDNS at `/etc/coredns/custom/`, and CoreDNS imports `*.server` and
# `*.override` from there. Only one such ConfigMap exists cluster-wide;
# any future custom zones / rewrites must be added here, not in a second
# ConfigMap.
#
# Today: forwards the full magic-subdomain zone to Tailscale's MagicDNS so
# in-cluster pods can resolve `*.MAGIC_DOMAIN` Tailscale FQDNs (e.g.
# `vault.MAGIC_DOMAIN`, `registry.MAGIC_DOMAIN`). Lives in `nextcloud/`
# because most services that consume the zone live in this deployment;
# moved here from `vault/dns.tf` so the file isn't tied to Vault.
resource "kubernetes_config_map" "kube_system_coredns_override" {
  metadata {
    name      = "coredns-custom" # K3s expects this exact name
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
