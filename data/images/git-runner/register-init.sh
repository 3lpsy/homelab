#!/usr/bin/env bash
# Init container: register the runner (if not already) and hand the .runner
# file off to the unprivileged runner uid. Runs as root so it can read the
# CSI-mounted admin secret and chown the result. Exits before the main
# (workflow-executing) container starts, so that container never holds the
# Forgejo admin credential.
set -euo pipefail

. /register.sh

FORGEJO_ADMIN_PASSWORD="$(cat /mnt/secrets/forgejo_admin_password)"
export FORGEJO_ADMIN_PASSWORD

maybe_register

# The daemon runs as uid 1001 and must read .runner.
if [ -f "$RUNNER_FILE" ]; then
  chown 1001:1001 "$RUNNER_FILE" 2>/dev/null || true
fi
