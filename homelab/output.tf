
output "acme_account_key_pem" {
  value     = module.homelab-infra-tls.account_key_pem
  sensitive = true
}

output "tailnet_user_map" {
  value = module.tailnet-infra.user_map
}

output "headscale_server_fqdn" {
  value = module.headscale-infra-dns.dns_domain
}
