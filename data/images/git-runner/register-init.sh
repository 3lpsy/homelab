#!/usr/bin/env bash
# Init container: register the runner if not already (idempotent). Runs as the
# runner uid (1001); the admin secret is mounted mode 0644 so it's still
# readable, and writing .runner as 1001 matches the main container so it can
# rewrite it. Exits before the main (workflow-executing) container starts, so
# that container never holds the Forgejo admin credential. .runner persists on
# the /data PVC, so this is a no-op after the first registration.
set -euo pipefail

. /register.sh

FORGEJO_ADMIN_PASSWORD="$(cat /mnt/secrets/forgejo_admin_password)"
export FORGEJO_ADMIN_PASSWORD

maybe_register
