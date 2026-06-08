#!/usr/bin/env bash
# Main container: start a podman Docker-API socket, then the forgejo-runner
# daemon.
#
# Runs ROOTLESS as the `runner` user (uid 1001, set via the pod security
# context) in an UNPRIVILEGED pod → nested job containers map into the
# subuid/subgid range, so their root is an unprivileged host uid, not node root.
# graphroot is the emptyDir at /home/runner/.local/share/containers (set in
# storage.conf) to avoid overlay-on-overlay on the local-path PVC; the dirs
# below are emptyDir/PVC mounts made writable by fs_group=1001. Registration ran
# in the init container.
set -euo pipefail

# mkdir -p (NOT install -d): the emptyDir/PVC mounts already exist owned
# root:1001 (fs_group), and `install -d` would try to chmod them → EPERM as
# uid 1001. mkdir -p no-ops on existing dirs and creates /data/cache as 1001.
mkdir -p /run/podman /run/containers /home/runner/.local/share/containers /data/cache /data/build-cache

# /data/build-cache is bind-mounted into every job at /cache (read-write) for the
# dev-release incremental cache (CARGO_HOME/CARGO_TARGET_DIR + the staged binary
# handoff). Jobs run in their own user namespace (their root maps to a subuid, not
# 1001), so make the top dir world-writable to avoid cross-userns ownership
# friction. The runner owns it as uid 1001 and can chmod; || true keeps a transient
# chmod failure from crashlooping the runner.
chmod 0777 /data/build-cache || true

export HOME=/home/runner

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
