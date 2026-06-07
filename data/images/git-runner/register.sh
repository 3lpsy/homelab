#!/usr/bin/env bash
# Registration logic for the Forgejo Actions runner, factored into a sourced
# function so it can be unit-tested (test_register.py) without standing up a
# real Forgejo / podman.
#
# Reads from the environment:
#   RUNNER_FILE              path to the persisted .runner file (PVC)
#   GIT_FQDN                 Forgejo FQDN (git.<magic>)
#   PERSONAL_USER            Forgejo username the runner is scoped to
#   FORGEJO_ADMIN_PASSWORD   gitadmin password (init container only)
#   RUNNER_LABELS            comma-separated act_runner labels
#   RUNNER_NAME              optional, defaults to git-runner
#
# Uses the admin account + the `Sudo:` header to mint a USER-scoped
# registration token, so the runner only ever serves the personal user's
# repos (Forgejo security docs: use the tightest scope). The admin password
# lives only in the init container that calls this; the long-running runner
# never mounts it.

maybe_register() {
  if [ -f "$RUNNER_FILE" ]; then
    echo "git-runner: $RUNNER_FILE present — already registered, skipping"
    return 0
  fi

  echo "git-runner: registering with https://${GIT_FQDN} (user-scoped: ${PERSONAL_USER})"

  local token
  # pipefail (set by the caller) makes a curl failure abort before jq runs.
  token="$(curl -fsS \
    -u "gitadmin:${FORGEJO_ADMIN_PASSWORD}" \
    -H "Sudo: ${PERSONAL_USER}" \
    "https://${GIT_FQDN}/api/v1/user/actions/runners/registration-token" \
    | jq -er '.token')"

  forgejo-runner register --no-interactive \
    --instance "https://${GIT_FQDN}" \
    --token "$token" \
    --name "${RUNNER_NAME:-git-runner}" \
    --labels "${RUNNER_LABELS}" \
    --config /config/config.yaml

  echo "git-runner: registered"
}
