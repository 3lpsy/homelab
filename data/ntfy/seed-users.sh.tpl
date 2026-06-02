#!/bin/sh
# Seed ntfy users + ACLs from Vault-mounted password files.
#
# Idempotent: runs on every pod start. Existing users get removed and
# recreated with the current TF-managed password + role + access. Users
# NOT in this list are left alone, so runtime additions via the ntfy
# admin API are preserved across restarts.
#
# Why init container, not ConfigMap auth-users: the ConfigMap is included
# (plaintext) in Velero backup tarballs in S3. Any bcrypt hash there is
# offline-attackable. Seeding via CLI keeps user data only in the SQLite
# auth-file on the PVC (Velero FSB / kopia uploader = client-side
# encrypted before S3).

set -eu

SECRETS_DIR=/mnt/secrets

echo "[ntfy-seed] starting"

# Wipe and re-seed on every restart. Reasons:
#   - TF is now the sole source of truth for users/roles/access.
#   - Users seeded via the legacy `auth-users` YAML config carry a
#     "provisioned" flag in user.db that blocks `ntfy user change-pass`
#     and `user remove` — the CLI rejects them with "cannot change or
#     delete provisioned user". Wiping clears that flag.
# Trade-off: any user added at runtime (via the ntfy admin API) is gone
# on next pod restart. That is intentional under the new model.
rm -f /var/lib/ntfy/user.db

# `ntfy user add` refuses to operate without an existing auth-file,
# saying "please start the server at least once to create it". Bootstrap
# an empty schema by running ntfy serve for a few seconds and timing out.
# This is safe: the main ntfy container has not started yet (init
# containers run sequentially), so the port is free.
echo "[ntfy-seed] bootstrapping empty user.db via brief ntfy serve"
timeout 3 ntfy serve >/dev/null 2>&1 || true

if [ ! -f /var/lib/ntfy/user.db ]; then
  echo "[ntfy-seed] FATAL: ntfy serve did not create user.db" >&2
  exit 1
fi

%{ for user, role in users ~}
echo "[ntfy-seed] ${user} (${role})"
NTFY_PASSWORD="$(cat $${SECRETS_DIR}/password_${user})"
export NTFY_PASSWORD

ntfy user add --role=${role} ${user}

unset NTFY_PASSWORD

%{ if role == "user" ~}
ntfy access ${user} "*" rw
%{ endif ~}

%{ endfor ~}

echo "[ntfy-seed] done"
