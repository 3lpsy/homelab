# Zitadel-authenticated SSH into the opencode container, via opkssh
# (OpenPubkey SSH). The opencode container runs sshd whose
# AuthorizedKeysCommand is `opkssh verify` (baked into the image — see
# data/images/opencode/Dockerfile + data/opencode/entrypoint.sh). The
# client runs `opkssh login` (browser → Zitadel), which embeds the Zitadel
# ID token into an SSH cert; on connect, opkssh verifies that token against
# Zitadel's JWKS and the /etc/opk policy this file renders. No static SSH
# keys, no CA. This is the "tailscale ssh into opencode" goal, solved with
# a plain sshd over the tailnet (the tailscale sidecar advertises the node;
# `--ssh` is intentionally NOT enabled, so tailscaled doesn't grab :22).
#
# Dedicated Zitadel project + app on purpose: opkssh's README warns never
# to reuse a client_id across services (token replay), and
# feedback_zitadel_one_project_per_service keeps the id_token `aud` clean.

locals {
  # Exact Zitadel issuer URL — must match what the client passes to
  # `opkssh login --provider="<issuer>,<client_id>"` AND what lands in
  # /etc/opk/{providers,auth_id} below, or token verification fails.
  opencode_ssh_issuer = "https://${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"
}

resource "zitadel_project" "opencode_ssh" {
  name   = "opencode-ssh"
  org_id = data.zitadel_organizations.homelab.ids[0]

  # has_project_check=true → Zitadel refuses to mint a token for any user
  # without a grant on this project. That single grant
  # (zitadel_user_grant.opencode_ssh_personal) is the whole authz surface,
  # mirroring the opencode web app's per-user gate.
  has_project_check        = true
  project_role_assertion   = false
  project_role_check       = false
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"
}

resource "zitadel_application_oidc" "opencode_ssh" {
  name       = "opencode-ssh"
  org_id     = data.zitadel_organizations.homelab.ids[0]
  project_id = zitadel_project.opencode_ssh.id

  # Public native client (PKCE, no secret). opkssh's Zitadel guidance:
  # "Do not use Confidential/Secret mode, only client ID is needed."
  app_type         = "OIDC_APP_TYPE_NATIVE"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_NONE"

  response_types = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types    = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"]

  # opkssh uses three FIXED loopback callback ports (it tries each in turn
  # in case one is busy locally); all three must be registered. Loopback
  # http redirects are permitted for NATIVE apps without dev_mode. If a
  # future Zitadel rejects http+localhost here, set dev_mode = true.
  redirect_uris = [
    "http://localhost:3000/login-callback",
    "http://localhost:10001/login-callback",
    "http://localhost:11110/login-callback",
  ]

  # Fold profile/email claims into the id_token (opkssh reads identity from
  # the id_token). Authorization below keys on `sub`, but this keeps email
  # available for readability/alternate policies.
  id_token_userinfo_assertion = true
  dev_mode                    = false
}

# Personal user is the only granted identity (mirrors the opencode web app).
resource "zitadel_user_grant" "opencode_ssh_personal" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.personal.id
  project_id = zitadel_project.opencode_ssh.id
  role_keys  = []
}

# opkssh server config, copied into /etc/opk by entrypoint.sh with the
# perms opkssh enforces (auth_id → root:opksshuser 640).
#
#   providers: "<issuer> <client_id> <expiration>" — expiration is opkssh's
#     cert/token TTL. Valid tokens: 12h/24h/48h/1week/oidc/oidc-refreshed
#     (NOT "7d"). 1week chosen for fewer browser logins + smoother Zed
#     reconnects; revocation latency is up to that TTL.
#   auth_id: "<principal> <identity> <issuer>", one mapping per line. Maps an
#     SSH login user (principal) to the personal user's email. opkssh matches
#     the auth_id identity against the token's email/group, NOT a raw numeric
#     `sub` (a sub value here silently never matches), so this uses
#     var.zitadel_personal_user.email (the verified contact email, — the `email` claim opkssh reads, distinct from the
#     jim@<magic> login name per user_identity_convention).
#
#     BOTH `user` and `root` principals are authorized for the same identity:
#     opencode runs as the unprivileged `user` (the agent), and `root` is the
#     break-glass principal (the ONLY way to root in the container — there is
#     no in-container privesc path). So the same OIDC login lets you
#     `ssh user@opencode` (normal) or `ssh root@opencode` (admin).
resource "kubernetes_config_map" "opencode_opk" {
  metadata {
    name      = "opencode-opk"
    namespace = kubernetes_namespace.opencode.metadata[0].name
  }
  data = {
    "providers" = "${local.opencode_ssh_issuer} ${zitadel_application_oidc.opencode_ssh.client_id} 1week"
    "auth_id" = join("\n", [
      "user ${var.zitadel_personal_user.email} ${local.opencode_ssh_issuer}",
      "root ${var.zitadel_personal_user.email} ${local.opencode_ssh_issuer}",
    ])
  }
}
