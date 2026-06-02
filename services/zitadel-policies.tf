# Instance-wide default policies. Override Zitadel built-ins for a
# single-user homelab posture. Per-org overrides (zitadel_login_policy
# etc.) intentionally not used — only one org exists.

resource "zitadel_default_login_policy" "default" {
  # Auth surfaces
  user_login         = true                          # username + password allowed
  allow_register     = false                         # no self-signup
  allow_external_idp = false                         # no upstream Google/GitHub etc.
  passwordless_type  = "PASSWORDLESS_TYPE_ALLOWED"   # passkeys welcome
  ignore_unknown_usernames = true                    # don't leak user existence
  hide_password_reset      = true                    # passkey-first; reset link off intentionally
  allow_domain_discovery   = false
  disable_login_with_email = false                   # keep email as alt loginname
  disable_login_with_phone = true                    # no SMS

  # MFA — relaxed default; tighten to true once daily flow is stable.
  force_mfa            = false
  force_mfa_local_only = false
  second_factors       = ["SECOND_FACTOR_TYPE_OTP", "SECOND_FACTOR_TYPE_U2F"]
  multi_factors        = ["MULTI_FACTOR_TYPE_U2F_WITH_VERIFICATION"]

  # Session lifetimes — Zitadel example values; sensible for browser SSO.
  password_check_lifetime       = "240h0m0s" # 10d
  external_login_check_lifetime = "240h0m0s"
  multi_factor_check_lifetime   = "24h0m0s"
  mfa_init_skip_lifetime        = "720h0m0s" # 30d
  second_factor_check_lifetime  = "24h0m0s"

  # Where to land when login completes without a downstream client (i.e.
  # someone hits / directly).
  default_redirect_uri = "https://${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}/ui/console"
}

resource "zitadel_default_password_complexity_policy" "default" {
  min_length    = "12"
  has_uppercase = true
  has_lowercase = true
  has_number    = true
  has_symbol    = true
}

resource "zitadel_default_lockout_policy" "default" {
  max_password_attempts = "5"
  max_otp_attempts      = "5"
}

resource "zitadel_default_domain_policy" "default" {
  # Loginname has email-shape: <userName>@<org-primary-domain>. The shorter
  # primary domain (var.headscale_magic_domain) is added + verified + flipped
  # primary by services/zitadel-org-domain.tf — see that file for the full
  # ValidateOrgDomain dance (Zitadel TF provider only owns the unverified entry).
  user_login_must_be_domain = true
  validate_org_domains      = true

  # No SMTP wired — don't enforce sender-address matching.
  smtp_sender_address_matches_instance_domain = false
}
