locals {
  # Tailnet magic-domain suffix shared by every per-service FQDN.
  # Per-service FQDN: "${var.<svc>_domain}.${local.magic_fqdn_suffix}".
  magic_fqdn_suffix = "${var.headscale_subdomain}.${var.headscale_magic_domain}"

  # OIDC fan-in: every consumer pinning oidc.<magic> to the Zitadel
  # Service ClusterIP repeats the same 3-line host_aliases block. Centralize
  # the {ip, hostnames} pair here so consumer pods can collapse to
  #   host_aliases {
  #     ip        = local.oidc_host_alias.ip
  #     hostnames = local.oidc_host_alias.hostnames
  #   }
  # Migrations land opportunistically alongside other consumer edits; this
  # local is a no-op until referenced.
  oidc_host_alias = {
    ip        = data.terraform_remote_state.vault_conf.outputs.zitadel_cluster_ip
    hostnames = ["${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"]
  }
}
