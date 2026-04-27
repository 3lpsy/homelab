
output "acme_account_key_pem" {
  value     = module.homelab-infra-tls.account_key_pem
  sensitive = true
}

output "tailnet_user_map" {
  value = module.tailnet-infra.user_map
}

output "tailnet_user_name_map" {
  value = module.tailnet-infra.user_name_map
}

output "headscale_server_fqdn" {
  value = module.headscale-infra-dns.dns_domain
}

output "node_preauth_key" {
  value     = module.tailnet-infra.nomad_server_preauth_key
  sensitive = true
}

output "headscale_ec2_public_ip" {
  value = module.headscale-infra.public_ip
}

output "headscale_ec2_ssh_user" {
  value = module.headscale-infra.ssh_user
}

output "headscale_ec2_tailnet_hostname" {
  value = "headscale-host"
}

output "acme_registration_email" {
  value = module.homelab-infra-tls.registration_email_address
}

output "route53_server_zone_id" {
  value = module.headscale-infra-dns.server_zone_id
}

output "route53_magic_zone_id" {
  value = module.headscale-infra-dns.magic_zone_id
}

output "route53_magic_root_zone_id" {
  value = module.headscale-infra-dns.magic_root_zone_id
}

# output "litellm_master_key" {
#   value     = module.litellm.master_key
#   sensitive = true
# }
