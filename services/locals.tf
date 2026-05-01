locals {
  # Tailnet magic-domain suffix shared by every per-service FQDN.
  # Per-service FQDN: "${var.<svc>_domain}.${local.magic_fqdn_suffix}".
  magic_fqdn_suffix = "${var.headscale_subdomain}.${var.headscale_magic_domain}"
}
