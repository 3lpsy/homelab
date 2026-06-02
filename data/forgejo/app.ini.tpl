; Forgejo config — non-secret keys only.
;
; Secrets (SECRET_KEY, INTERNAL_TOKEN, OAUTH2_JWT_SECRET, LFS_JWT_SECRET)
; land via FORGEJO__<section>__<KEY> env vars sourced from the Vault CSI
; secret. This file is mounted read-only at /etc/gitea/app.ini.
;
; The rootless image runs as UID 1000 and looks for app.ini under
; /etc/gitea/ by default — we override APP_INI_FILE in the Deployment.

APP_NAME = Homelab Forge
RUN_USER = git
RUN_MODE = prod
WORK_PATH = /var/lib/gitea

[database]
DB_TYPE = sqlite3
PATH    = /var/lib/gitea/data/forgejo.db
LOG_SQL = false

[server]
DOMAIN           = ${git_fqdn}
ROOT_URL         = https://${git_fqdn}/
HTTP_PORT        = 3000
PROTOCOL         = http
APP_DATA_PATH    = /var/lib/gitea/data
; SSH lives in-pod on :2222 (rootless can't bind <1024). The Tailscale
; sidecar advertises tailnet tcp/22 → :2222 so external clients use
; the conventional port 22 while opencode talks to :2222 directly via
; ClusterIP.
SSH_DOMAIN       = ${git_fqdn}
SSH_PORT         = 22
SSH_LISTEN_PORT  = 2222
SSH_LISTEN_HOST  = 0.0.0.0
START_SSH_SERVER = true
DISABLE_SSH      = false
LFS_START_SERVER = false
OFFLINE_MODE     = true

[repository]
DEFAULT_BRANCH         = main
DEFAULT_PRIVATE        = private
DEFAULT_REPO_UNITS     = repo.code,repo.releases,repo.issues,repo.pulls,repo.wiki

[service]
DISABLE_REGISTRATION                = true
REQUIRE_SIGNIN_VIEW                 = true
ENABLE_BASIC_AUTHENTICATION         = true
ENABLE_REVERSE_PROXY_AUTHENTICATION = false
DEFAULT_KEEP_EMAIL_PRIVATE          = true
DEFAULT_USER_VISIBILITY             = private
DEFAULT_ORG_VISIBILITY              = private
NO_REPLY_ADDRESS                    = noreply.${magic_domain}

[security]
INSTALL_LOCK             = true
PASSWORD_HASH_ALGO       = argon2
DISABLE_GIT_HOOKS        = true
MIN_PASSWORD_LENGTH      = 12

[openid]
ENABLE_OPENID_SIGNIN = false
ENABLE_OPENID_SIGNUP = false

[oauth2_client]
; Hard-deny: no auto-creation of Forgejo accounts from unknown OIDC users.
; Combined with has_project_check=true on zitadel_project.git, this means
; only the explicitly-granted personal user (zitadel_user_grant.git_personal_user)
; can sign in via OIDC. Adding another user later is a two-step process:
; (1) add a zitadel_user_grant for them, (2) pre-create the Forgejo user
; with matching email (bootstrap script step 3 pattern).
ENABLE_AUTO_REGISTRATION                  = false
; Valid USERNAME values are exactly `userid|nickname|email` — NOT
; `preferred_username` (would be silently invalid). With AUTO_REGISTRATION
; off this only matters as a sanity setting; the live linking path is
; ACCOUNT_LINKING=auto matching on email, which routes through `email`
; here anyway.
USERNAME                                  = email
; Silent link on email match — pre-created Forgejo user picks up the
; Zitadel identity on first sign-in with no password prompt. Safe because
; the email value flows from var.zitadel_personal_user.email (TF-managed,
; identical on both ends).
ACCOUNT_LINKING                           = auto
UPDATE_AVATAR                             = false
OPENID_CONNECT_SCOPES                     = openid profile email

[oauth2]
ENABLED = true

[session]
PROVIDER       = file
COOKIE_SECURE  = true

[log]
MODE  = console
LEVEL = Info

[ui]
DEFAULT_THEME = forgejo-auto

[metrics]
ENABLED = false

[actions]
ENABLED = false

[federation]
ENABLED = false
