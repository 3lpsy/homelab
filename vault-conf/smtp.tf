# Outbound SMTP creds (AWS SES) materialized into Vault KV so services
# can consume via CSI rather than passing through TF state. Source of
# truth is homelab/ses.tf which manages the SES domain identity, DKIM,
# IAM user, and v4-derived SMTP password.

resource "vault_kv_secret_v2" "smtp" {
  mount = vault_mount.kv.path
  name  = "smtp/config"

  data_json = jsonencode({
    host         = data.terraform_remote_state.homelab.outputs.ses_smtp_host
    port         = tostring(data.terraform_remote_state.homelab.outputs.ses_smtp_port)
    user         = data.terraform_remote_state.homelab.outputs.ses_smtp_user
    password     = data.terraform_remote_state.homelab.outputs.ses_smtp_password
    from_domain  = data.terraform_remote_state.homelab.outputs.ses_mail_from_domain
    from_address = data.terraform_remote_state.homelab.outputs.ses_default_from_address
    from_name    = "Homelab"
  })
}

# Read policy attached by services that consume SMTP. The default
# service-tls-vault module gives each service a policy scoped to
# secret/data/<svc>/*; this policy unlocks the shared smtp/config path.
# Bind by adding `vault_policy.smtp_reader.name` to the per-service
# Vault role's token_policies.
resource "vault_policy" "smtp_reader" {
  name = "smtp-reader"

  policy = <<EOT
path "${vault_mount.kv.path}/data/smtp/config" {
  capabilities = ["read"]
}
EOT
}
