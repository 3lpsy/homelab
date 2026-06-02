# Personal human user seeded in Zitadel for SSO onboarding.
#
# Profile fields come from var.zitadel_personal_user. The bootstrap password
# is generated locally (random_password) and stashed in Vault — Zitadel
# requires the user to change it on first login, so it's a one-shot.
#
# Adding more humans later: extend this file with another resource pair
# (or refactor to for_each over a map var). Per memory
# `feedback_zitadel_user_mapping_clarify.md` we ask before creating any
# new Zitadel user — don't auto-mint identities for newly-onboarded
# services.

resource "random_password" "zitadel_personal_user_initial" {
  length  = 24
  special = true
}

resource "zitadel_human_user" "personal" {
  org_id             = data.zitadel_organizations.homelab.ids[0]
  user_name          = var.zitadel_personal_user.user_name
  first_name         = var.zitadel_personal_user.first_name
  last_name          = var.zitadel_personal_user.last_name
  display_name       = "${var.zitadel_personal_user.first_name} ${var.zitadel_personal_user.last_name}"
  nick_name          = var.zitadel_personal_user.nick_name
  preferred_language = "en"
  email              = var.zitadel_personal_user.email
  # Skip Zitadel's email-verify roundtrip — we own the email domain and
  # the user is being seeded by an admin, not self-registering.
  is_email_verified = true
  initial_password  = random_password.zitadel_personal_user_initial.result
}

# Stash the one-shot bootstrap password in Vault. Read once with
# `vault kv get secret/zitadel-users/<user_name>`, sign in, register a
# passkey, then drop the password from your head.
resource "vault_kv_secret_v2" "zitadel_personal_user" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "zitadel-users/${var.zitadel_personal_user.user_name}"
  data_json = jsonencode({
    user_name        = var.zitadel_personal_user.user_name
    email            = var.zitadel_personal_user.email
    initial_password = random_password.zitadel_personal_user_initial.result
  })
  # No ignore_changes: TF is the source of truth. Rotating the password
  # is `terraform apply -replace=random_password.zitadel_personal_user_initial`
  # which generates a new value AND pushes it to Vault in one apply.
}

resource "random_password" "zitadel_partner_user_initial" {
  length  = 24
  special = true
}

resource "zitadel_human_user" "partner" {
  org_id             = data.zitadel_organizations.homelab.ids[0]
  user_name          = var.zitadel_partner_user.user_name
  first_name         = var.zitadel_partner_user.first_name
  last_name          = var.zitadel_partner_user.last_name
  display_name       = "${var.zitadel_partner_user.first_name} ${var.zitadel_partner_user.last_name}"
  nick_name          = var.zitadel_partner_user.nick_name
  preferred_language = "en"
  email              = var.zitadel_partner_user.email
  is_email_verified  = true
  initial_password   = random_password.zitadel_partner_user_initial.result
}

resource "vault_kv_secret_v2" "zitadel_partner_user" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "zitadel-users/${var.zitadel_partner_user.user_name}"
  data_json = jsonencode({
    user_name        = var.zitadel_partner_user.user_name
    email            = var.zitadel_partner_user.email
    initial_password = random_password.zitadel_partner_user_initial.result
  })
}
