#!/bin/sh
# Forgejo bootstrap — idempotent post-deploy.
#
# 1. Ensure local `admin` user exists with Vault-tracked password (Vault is
#    source of truth per feedback_vault_app_passwords; rotate via
#    `terraform apply -replace=random_password.git_admin_password`).
# 2. Ensure Zitadel OIDC auth source exists with current client_id/secret.
# 3. Pre-create personal Zitadel-mapped user as admin so the first OIDC
#    sign-in account-links to a Forgejo admin (rather than auto-provisioning
#    a fresh non-admin user). Username matches preferred_username (claimed
#    as `<user_name>@<magic_domain>` after services/zitadel-org-domain.tf
#    flips primary), which matches USERNAME=preferred_username in
#    [oauth2_client] of app.ini.
# 4. Register personal user's SSH key (from `git-personal-pubkey` CM, sourced
#    from var.git_personal_user_ssh_pub_key).
# 5. Ensure local `opencode` user exists with Vault-tracked password.
# 6. Register opencode's TF-generated SSH key (from `git-opencode-pubkey` CM).
#
# Runs as the forgejo container user (UID 1000) so `forgejo` CLI calls reach
# the same /var/lib/gitea dir + /etc/gitea/app.ini that the live process uses.
# No jq: REST responses are parsed with grep against the well-known JSON
# shape ({"title":"...","key":"..."}) which is stable across Forgejo versions.

set -eu

# Dials Forgejo via the in-cluster Service. The Job pod's host_aliases pins
# ${git_fqdn} to the git Service ClusterIP so the cert's SAN matches (cert
# is for ${git_fqdn}, not for the cluster.local DNS name).
API="https://${git_fqdn}/api/v1"
# `admin` is on Forgejo's reserved-usernames list (along with api, user,
# oauth, org, install, etc.). Use `gitadmin` for the local break-glass
# account — same role, just not on the reserved list. Vault path remains
# git/config:admin_password (key name, not username).
ADMIN_USER="gitadmin"
ADMIN_EMAIL="gitadmin@${magic_domain}"
# Personal Forgejo username = the local part (no `@<magic>`). Forgejo
# rejects `@` in usernames. On first OIDC sign-in Zitadel returns
# preferred_username=`<user_name>@<magic>` which won't match by username,
# so ACCOUNT_LINKING=login falls back to email matching against the
# pre-created PERSONAL_EMAIL and prompts the user to link the accounts
# (per feedback_zitadel_email_claim_override — manual link via the
# /user-settings page, but for a matching email the prompt is one click).
PERSONAL_USER="${personal_username}"
PERSONAL_EMAIL="${personal_email}"
OPENCODE_USER="opencode"
OPENCODE_EMAIL="opencode@${magic_domain}"
PERSONAL_KEY_TITLE="${personal_key_title}"
OPENCODE_KEY_TITLE="${opencode_key_title}"

# Required env (via envFrom on the Job):
#   ADMIN_PASSWORD, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET,
#   OPENCODE_USER_PASSWORD, PERSONAL_USER_PASSWORD

log() { echo "[forgejo-bootstrap] $*"; }

# ─── 0. Wait for Forgejo to serve the API ──────────────────────────────────
# /api/healthz is unauthenticated by design (no REQUIRE_SIGNIN_VIEW gate);
# /api/v1/* including /version IS gated by app.ini's REQUIRE_SIGNIN_VIEW.
HEALTH="https://${git_fqdn}/api/healthz"
log "waiting for Forgejo health at $HEALTH"
i=0
until curl -fsS "$HEALTH" >/dev/null 2>&1; do
  i=$((i+1))
  if [ $i -gt 60 ]; then
    log "FATAL: Forgejo did not become healthy within 300s"
    exit 1
  fi
  sleep 5
done
log "Forgejo is healthy"

# Common curl args — admin basic auth, fail on non-2xx, silent.
CURL_ADMIN="curl -fsS -u $ADMIN_USER:$ADMIN_PASSWORD"

# ─── 1. Admin user (offline CLI, no network) ───────────────────────────────
# user exists check via the offline CLI to avoid chicken-and-egg with the
# password we're about to set/reset.
if ! forgejo admin user list --admin | awk 'NR>1 {print $2}' | grep -qx "$ADMIN_USER"; then
  log "creating admin user"
  forgejo admin user create \
    --admin \
    --username "$ADMIN_USER" \
    --email "$ADMIN_EMAIL" \
    --password "$ADMIN_PASSWORD" \
    --must-change-password=false
else
  log "admin user exists; reconciling password from Vault"
  forgejo admin user change-password --username "$ADMIN_USER" --password "$ADMIN_PASSWORD" --must-change-password=false
fi

# ─── 2. Zitadel OIDC auth source ───────────────────────────────────────────
AUTH_NAME="zitadel"
DISCOVERY_URL="https://${zitadel_fqdn}/.well-known/openid-configuration"
# `forgejo admin auth list` prints a tab-padded table:
#   ID Name Type Enabled
# Match the Name column ($2) for our source. awk handles multi-space padding
# from the cobra tabwriter defaults.
AUTH_LIST=$(forgejo admin auth list 2>/dev/null || true)
AUTH_ID=$(printf '%s\n' "$AUTH_LIST" | awk -v n="$AUTH_NAME" '$2 == n {print $1; exit}')

if [ -z "$AUTH_ID" ]; then
  log "adding $AUTH_NAME OIDC source"
  # --scopes is a cobra StringSliceVar: comma-separated values.
  # Explicit quoting around every value-bearing arg so embedded chars in
  # the client secret never get word-split into a separate arg.
  forgejo admin auth add-oauth \
    --name "$AUTH_NAME" \
    --provider openidConnect \
    --key "$OIDC_CLIENT_ID" \
    --secret "$OIDC_CLIENT_SECRET" \
    --auto-discover-url "$DISCOVERY_URL" \
    --scopes "openid,profile,email" \
    --skip-local-2fa=true
else
  log "updating existing $AUTH_NAME OIDC source (id=$AUTH_ID)"
  forgejo admin auth update-oauth \
    --id "$AUTH_ID" \
    --name "$AUTH_NAME" \
    --provider openidConnect \
    --key "$OIDC_CLIENT_ID" \
    --secret "$OIDC_CLIENT_SECRET" \
    --auto-discover-url "$DISCOVERY_URL" \
    --scopes "openid,profile,email" \
    --skip-local-2fa=true
fi

# ─── 3. Personal user pre-create + promote to admin ────────────────────────
# The OAuth source auto-creates users on first login (ENABLE_AUTO_REGISTRATION
# in app.ini), but auto-created users are non-admin. Pre-creating with the
# expected preferred_username lets ACCOUNT_LINKING=login attach the OIDC
# identity to this existing admin account on first sign-in.
if ! $CURL_ADMIN "$API/users/$PERSONAL_USER" >/dev/null 2>&1; then
  log "creating personal user $PERSONAL_USER"
  $CURL_ADMIN -X POST -H "Content-Type: application/json" "$API/admin/users" \
    -d "{\"login_name\":\"$PERSONAL_USER\",\"username\":\"$PERSONAL_USER\",\"email\":\"$PERSONAL_EMAIL\",\"password\":\"$PERSONAL_USER_PASSWORD\",\"must_change_password\":false,\"source_id\":0}" >/dev/null
else
  # Reconcile password + email from Vault/TF so the /user/link_account
  # prompt (entered once on first OIDC sign-in) can be answered with
  # `vault kv get -field=personal_user_password git/config`. Email is
  # reconciled too so changes to the `personal_email` template var
  # propagate to the existing user without needing to delete + recreate.
  log "personal user exists; reconciling password + email from Vault/TF"
  $CURL_ADMIN -X PATCH -H "Content-Type: application/json" "$API/admin/users/$PERSONAL_USER" \
    -d "{\"password\":\"$PERSONAL_USER_PASSWORD\",\"email\":\"$PERSONAL_EMAIL\"}" >/dev/null
fi
log "promoting $PERSONAL_USER to admin (idempotent)"
# PATCH body intentionally admin-only: Forgejo's EditUser handler requires
# source_id + login_name to be set together or omitted together. Sending
# source_id=0 would un-link the OIDC binding after the first sign-in.
$CURL_ADMIN -X PATCH -H "Content-Type: application/json" "$API/admin/users/$PERSONAL_USER" \
  -d '{"admin":true}' >/dev/null

# ─── 4. Register personal user's SSH key ───────────────────────────────────
PERSONAL_PUB=$(cat /etc/keys/personal.pub)
if $CURL_ADMIN "$API/users/$PERSONAL_USER/keys" 2>/dev/null | grep -q "\"title\":\"$PERSONAL_KEY_TITLE\""; then
  log "personal SSH key already registered (title=$PERSONAL_KEY_TITLE)"
else
  log "registering personal SSH key (title=$PERSONAL_KEY_TITLE)"
  $CURL_ADMIN -X POST -H "Content-Type: application/json" \
    "$API/admin/users/$PERSONAL_USER/keys" \
    -d "{\"title\":\"$PERSONAL_KEY_TITLE\",\"key\":\"$PERSONAL_PUB\",\"read_only\":false}" >/dev/null
fi

# ─── 5. Opencode local user (RESTRICTED, no org creation) ──────────────────
# opencode is an automated agent: create it as a RESTRICTED account so it can
# only see/interact with repos + orgs where it's an explicit collaborator/member
# (not the whole instance), and with org creation disabled. Both are enforced
# idempotently below so they also apply to a pre-existing user / correct drift.
if ! $CURL_ADMIN "$API/users/$OPENCODE_USER" >/dev/null 2>&1; then
  log "creating opencode user (restricted)"
  $CURL_ADMIN -X POST -H "Content-Type: application/json" "$API/admin/users" \
    -d "{\"login_name\":\"$OPENCODE_USER\",\"username\":\"$OPENCODE_USER\",\"email\":\"$OPENCODE_EMAIL\",\"password\":\"$OPENCODE_USER_PASSWORD\",\"must_change_password\":false,\"source_id\":0,\"restricted\":true}" >/dev/null
else
  log "opencode user exists; reconciling password from Vault"
  # Password-only PATCH for a local user — Forgejo uses the existing
  # auth source from the user record (source_id=0 = local) without
  # needing it in the body.
  $CURL_ADMIN -X PATCH -H "Content-Type: application/json" "$API/admin/users/$OPENCODE_USER" \
    -d "{\"password\":\"$OPENCODE_USER_PASSWORD\"}" >/dev/null
fi

# Enforce restricted + disable org creation (idempotent; covers the create path,
# the reconcile path, and any manual drift). EditUserOption: restricted +
# allow_create_organization. login_name/source_id omitted (opencode is local;
# the "must be set together or omitted together" rule is satisfied by omitting
# both, exactly like the password-only PATCH above).
log "enforcing restricted + no-org-creation on $OPENCODE_USER"
$CURL_ADMIN -X PATCH -H "Content-Type: application/json" "$API/admin/users/$OPENCODE_USER" \
  -d "{\"restricted\":true,\"allow_create_organization\":false}" >/dev/null

# ─── 6. Register opencode SSH key ──────────────────────────────────────────
OPENCODE_PUB=$(cat /etc/keys/opencode.pub)
if $CURL_ADMIN "$API/users/$OPENCODE_USER/keys" 2>/dev/null | grep -q "\"title\":\"$OPENCODE_KEY_TITLE\""; then
  log "opencode SSH key already registered (title=$OPENCODE_KEY_TITLE)"
else
  log "registering opencode SSH key (title=$OPENCODE_KEY_TITLE)"
  $CURL_ADMIN -X POST -H "Content-Type: application/json" \
    "$API/admin/users/$OPENCODE_USER/keys" \
    -d "{\"title\":\"$OPENCODE_KEY_TITLE\",\"key\":\"$OPENCODE_PUB\",\"read_only\":false}" >/dev/null
fi

# ─── 7. Mint opencode's scoped Forgejo API token + deliver to opencode ns ───
# opencode's `fj` CLI / API access. Mint a token scoped to
# ${opencode_token_scopes} for the RESTRICTED opencode user via the OFFLINE admin
# CLI (works without the user's password — and the password never leaves Forgejo).
# Then PATCH it into the opencode-forgejo-token Secret in the opencode namespace
# via the k8s API, authenticating with the bootstrap pod's `git` SA token (its
# only API right is get/patch on that one Secret). Idempotent: generate-access-token fails
# if the named token already exists, so re-runs skip and leave the already-
# delivered Secret intact. Rotate: delete the token in Forgejo + clear the
# Secret's data, then re-run this bootstrap.
OPENCODE_TOKEN_NAME="${opencode_token_name}"
OPENCODE_TOKEN_SCOPES="${opencode_token_scopes}"
OPENCODE_TOKEN_NS="${opencode_token_namespace}"
OPENCODE_TOKEN_SECRET="${opencode_token_secret}"

if NEW_TOKEN=$(forgejo admin user generate-access-token \
      --username "$OPENCODE_USER" \
      --token-name "$OPENCODE_TOKEN_NAME" \
      --scopes "$OPENCODE_TOKEN_SCOPES" \
      --raw 2>/dev/null); then
  log "minted opencode token '$OPENCODE_TOKEN_NAME' ($OPENCODE_TOKEN_SCOPES); delivering to $OPENCODE_TOKEN_NS/$OPENCODE_TOKEN_SECRET"
  SA=/var/run/secrets/kubernetes.io/serviceaccount
  K8S_TOKEN_B64=$(printf '%s' "$NEW_TOKEN" | base64 | tr -d '\n')
  curl -fsS \
    --cacert "$SA/ca.crt" \
    -H "Authorization: Bearer $(cat "$SA/token")" \
    -H "Content-Type: application/merge-patch+json" \
    -X PATCH \
    "https://kubernetes.default.svc/api/v1/namespaces/$OPENCODE_TOKEN_NS/secrets/$OPENCODE_TOKEN_SECRET" \
    -d "{\"data\":{\"token\":\"$K8S_TOKEN_B64\"}}" >/dev/null
  log "opencode token delivered (Reloader will roll opencode to pick it up)"
else
  log "opencode token '$OPENCODE_TOKEN_NAME' already exists; leaving existing Secret"
fi

log "bootstrap complete"
