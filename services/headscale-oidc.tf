# Headscale OIDC via Zitadel.
#
# Why this lives in services/ even though headscale runs on the EC2 host
# (homelab/): the OIDC client_id/client_secret come from a Zitadel app
# that only exists once vault-conf -> services has been applied. Headscale
# itself must boot before vault/services (deployment order 1 -> 3 -> 5),
# so the homelab-rendered base config carries no `oidc:` block. This file
# writes a slice file `/etc/headscale/_oidc.yaml` over SSH to the host;
# the merge wrapper in homelab/data/headscale/headscale-merge-config.sh
# concatenates it with the base config at every headscale start.
#
# Why slice-yaml + wrapper instead of env-file override:
# headscale's OIDC config has list-typed fields (`scope`, `allowed_users`).
# `viper.GetStringSlice` on env-source values does NOT split on commas
# (spf13/viper#380), so `HEADSCALE_OIDC_ALLOWED_USERS=a@x,b@x` parses as
# a single literal "a@x,b@x" and login fails. YAML lists parse correctly.
#
# Allowed users: only the existing personal user from
# services/zitadel-users.tf. Other tailnet users keep using pre-auth keys
# until they're explicitly onboarded to Zitadel
# (per memory feedback_zitadel_user_mapping_clarify.md).

locals {
  headscale_fqdn = data.terraform_remote_state.homelab.outputs.headscale_server_fqdn
  zitadel_issuer = "https://${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"
}

# Own project per memory feedback_zitadel_one_project_per_service.
resource "zitadel_project" "headscale" {
  name   = "headscale"
  org_id = data.zitadel_organizations.homelab.ids[0]

  project_role_assertion   = false
  project_role_check       = false
  has_project_check        = false
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"
}

resource "zitadel_application_oidc" "headscale" {
  name       = "Headscale"
  org_id     = data.zitadel_organizations.homelab.ids[0]
  project_id = zitadel_project.headscale.id

  # Headscale sends the redirect_uri with an explicit `:443` (it's derived
  # from `server_url` in headscale's config which includes the port).
  # OIDC matching is byte-exact, so register BOTH forms — with and without
  # the port — so it works regardless of what flow / version emits which.
  redirect_uris = [
    "https://${local.headscale_fqdn}/oidc/callback",
    "https://${local.headscale_fqdn}:443/oidc/callback",
  ]
  post_logout_redirect_uris = [
    "https://${local.headscale_fqdn}/",
    "https://${local.headscale_fqdn}:443/",
  ]

  response_types = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types = [
    "OIDC_GRANT_TYPE_AUTHORIZATION_CODE",
    "OIDC_GRANT_TYPE_REFRESH_TOKEN",
  ]

  app_type         = "OIDC_APP_TYPE_WEB"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_BASIC"
  version          = "OIDC_VERSION_1_0"

  access_token_type           = "OIDC_TOKEN_TYPE_BEARER"
  access_token_role_assertion = false
  id_token_role_assertion     = false
  id_token_userinfo_assertion = false

  dev_mode = false
}

resource "zitadel_user_grant" "headscale_personal_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.personal.id
  project_id = zitadel_project.headscale.id
  role_keys  = []
}

# Vault is canonical store for the OIDC creds (memory
# feedback_vault_app_passwords). The host-side slice file below is a
# materialized view rendered from the same TF state — rotation =
# `terraform apply -replace=zitadel_application_oidc.headscale` regenerates
# the secret AND pushes both the Vault entry and the host slice in one
# apply.
resource "vault_kv_secret_v2" "headscale_oidc" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "headscale/oidc"
  data_json = jsonencode({
    issuer        = local.zitadel_issuer
    client_id     = zitadel_application_oidc.headscale.client_id
    client_secret = zitadel_application_oidc.headscale.client_secret
    allowed_users = join(",", compact([
      var.zitadel_personal_user.email,
      var.zitadel_partner_user.email,
    ]))
  })
}

locals {
  headscale_oidc_slice = yamlencode({
    oidc = {
      issuer        = local.zitadel_issuer
      client_id     = zitadel_application_oidc.headscale.client_id
      client_secret = zitadel_application_oidc.headscale.client_secret
      scope         = ["openid", "profile", "email"]
      pkce = {
        enabled = true
      }
      expiry = "180d"
      # Personal + partner — match against the full OIDC `email` claim.
      # `strip_email_domain` was removed upstream (post-0.26); user-naming
      # is now driven by claim mapping rather than a domain-strip toggle.
      # `compact` drops the partner entry if zitadel_partner_user.email is
      # the empty string (partner not yet wired up).
      allowed_users = compact([
        var.zitadel_personal_user.email,
        var.zitadel_partner_user.email,
      ])
    }
  })
}

locals {
  headscale_pin_oidc_script = templatefile(
    "${path.module}/../data/scripts/headscale-pin-oidc.sh.tpl",
    { magic_fqdn_suffix = local.magic_fqdn_suffix },
  )
}

resource "null_resource" "headscale_oidc_slice" {
  triggers = {
    slice_hash       = sha1(local.headscale_oidc_slice)
    pin_script_hash  = sha1(local.headscale_pin_oidc_script)
    # Captured here so the destroy-time provisioner (which can only read
    # self.triggers.*, not data sources or vars) still has the SSH coords.
    host    = data.terraform_remote_state.homelab.outputs.headscale_ec2_public_ip
    user    = data.terraform_remote_state.homelab.outputs.headscale_ec2_ssh_user
    ssh_key = var.ssh_priv_key_path
  }

  connection {
    type        = "ssh"
    host        = self.triggers.host
    user        = self.triggers.user
    private_key = trimspace(file(self.triggers.ssh_key))
    timeout     = "2m"
  }

  provisioner "file" {
    content     = local.headscale_oidc_slice
    destination = "/home/${self.triggers.user}/_oidc.yaml"
  }

  # See data/scripts/headscale-pin-oidc.sh.tpl for why this pin exists.
  provisioner "file" {
    content     = local.headscale_pin_oidc_script
    destination = "/home/${self.triggers.user}/headscale-pin-oidc.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/${self.triggers.user}/_oidc.yaml /etc/headscale/_oidc.yaml",
      "sudo chown root:root /etc/headscale/_oidc.yaml",
      "sudo chmod 644 /etc/headscale/_oidc.yaml",
      "sudo install -o root -g root -m 0755 /home/${self.triggers.user}/headscale-pin-oidc.sh /usr/local/sbin/headscale-pin-oidc.sh",
      "rm /home/${self.triggers.user}/headscale-pin-oidc.sh",
      "sudo systemctl restart headscale",
      "sudo /usr/local/sbin/headscale-pin-oidc.sh",
    ]
  }

  # When the resource is removed (OIDC torn down), wipe the slice file
  # so the merge wrapper falls back to base-only config on next restart,
  # drop the /etc/hosts pin, and remove the helper script.
  provisioner "remote-exec" {
    when = destroy
    inline = [
      "sudo rm -f /etc/headscale/_oidc.yaml /usr/local/sbin/headscale-pin-oidc.sh",
      "sudo sed -i '/[[:space:]]oidc\\./d' /etc/hosts",
      "sudo systemctl restart headscale",
    ]
  }

  depends_on = [
    zitadel_application_oidc.headscale,
  ]
}
