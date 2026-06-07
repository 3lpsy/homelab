#!/usr/bin/env bash
# Main container: start a rootless podman Docker-API socket, then the
# forgejo-runner daemon. Registration already happened in the init container
# (register-init.sh), so this container does NOT mount the admin secret —
# it only needs the scoped .runner file on the PVC.
#
# Starts as root to chown the runtime dirs (emptyDir volumes mount root:root),
# then drops to the unprivileged `runner` uid for podman + the daemon. Mirrors
# the opencode rootless pattern (project_opencode_rootless_podman).
set -euo pipefail

RUN_UID=1001
RUN_GID=1001

# emptyDir volumes + PVC cache dir need to be writable by uid 1001.
install -d -o "$RUN_UID" -g "$RUN_GID" \
  /run/podman /run/containers \
  /home/runner/.local/share/containers \
  /data/cache
chown "$RUN_UID:$RUN_GID" /data 2>/dev/null || true

# Drop to the unprivileged runner with setpriv — NOT runuser/su. runuser goes
# through PAM, which shrinks the capability BOUNDING SET and strips CAP_SETUID;
# the setuid newuidmap helper then becomes euid 0 (passes the setuid check) but
# the kernel still denies the uid_map write ("Operation not permitted") because
# CAP_SETUID is gone from the bounding set. setpriv is a direct exec that
# preserves the bounding set. Do NOT pass --no-new-privs — rootless podman's
# setuid id-map helpers need privilege escalation. HOME must be set explicitly
# (setpriv does not). This mirrors data/opencode/entrypoint.sh.
export HOME=/home/runner
exec setpriv --reuid="$RUN_UID" --regid="$RUN_GID" --init-groups --inh-caps=-all \
  bash -c '
    set -eu
    podman system service --time=0 unix:///run/podman/podman.sock &
    for _ in $(seq 1 60); do
      [ -S /run/podman/podman.sock ] && break
      sleep 1
    done
    if [ ! -S /run/podman/podman.sock ]; then
      echo "git-runner: podman socket did not come up" >&2
      exit 1
    fi
    echo "git-runner: podman socket ready; starting daemon"
    exec forgejo-runner daemon --config /config/config.yaml
  '
