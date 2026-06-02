
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

output "provisioner_preauth_key" {
  description = "Bootstrap preauth key for the human operator's first device. 30d expiry, reusable. Read with `terraform -chdir=homelab output -raw provisioner_preauth_key` then `tailscale up --authkey=<key>`. Switch to OIDC after services apply."
  value       = module.tailnet-infra.provisioner_preauth_key
  sensitive   = true
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

# ---- AWS SES outbound mail ------------------------------------------------

output "ses_smtp_host" {
  description = "SES SMTP endpoint (region-specific). Use with port 587 + STARTTLS."
  value       = "email-smtp.${var.aws_region}.amazonaws.com"
}

output "ses_smtp_port" {
  value = 587
}

output "ses_smtp_user" {
  description = "Access key ID — use as SMTP username."
  value       = aws_iam_access_key.ses_smtp.id
}

output "ses_smtp_password" {
  description = "v4-derived SMTP password (HMAC-SHA256 of secret access key + region). Stash in Vault for downstream services."
  value       = aws_iam_access_key.ses_smtp.ses_smtp_password_v4
  sensitive   = true
}

output "ses_mail_from_domain" {
  description = "Verified SES domain identity. Use as From: address suffix (e.g. noreply@<this>)."
  value       = local.ses_mail_domain
}

output "ses_default_from_address" {
  description = "Suggested default From: for transactional mail."
  value       = "noreply@${local.ses_mail_domain}"
}

# output "litellm_master_key" {
#   value     = module.litellm.master_key
#   sensitive = true
# }
