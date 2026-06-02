# Zitadel outbound SMTP via AWS SES. Reads creds from Vault KV at
# secret/smtp/config, which vault-conf/smtp.tf populates from
# homelab/ses.tf outputs. set_active=true makes this the live provider.

data "vault_kv_secret_v2" "smtp" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = data.terraform_remote_state.vault_conf.outputs.smtp_kv_path
}

resource "zitadel_email_provider_smtp" "ses" {
  sender_address = data.vault_kv_secret_v2.smtp.data["from_address"]
  sender_name    = data.vault_kv_secret_v2.smtp.data["from_name"]
  tls            = true
  host           = "${data.vault_kv_secret_v2.smtp.data["host"]}:${data.vault_kv_secret_v2.smtp.data["port"]}"
  user           = data.vault_kv_secret_v2.smtp.data["user"]
  password       = data.vault_kv_secret_v2.smtp.data["password"]
  description    = "AWS SES outbound"
  set_active     = true

  # Zitadel rewrites the description server-side, appending the sender
  # domain in parens (e.g. "AWS SES outbound (mail.magic)"). This
  # caused every `terraform plan` to show a phantom description diff.
  # The rewrite is also tangled with a server-side projection bug
  # (smtp_configs6: multiple assignments to same column "password",
  # SQLSTATE 42601) that prevents the read-model from settling. Ignoring
  # this attribute mutes the noise; we own the desired prefix here, the
  # server owns the suffix.
  lifecycle {
    ignore_changes = [description]
  }
}
