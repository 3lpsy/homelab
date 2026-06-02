#!/bin/sh
# opencode container entrypoint: bring up opkssh-backed sshd (as root)
# alongside the opencode `web` server (dropped to the unprivileged `user`).
#
# The container STARTS as root — required so sshd can offer root login and
# so we can finalize the host key / /etc/opk perms / chown the runtime
# mounts. We then drop to `user` (uid 1001) to exec opencode, so the agent
# itself never runs as root. The ONLY path to root is authenticating to
# sshd as the `root` principal (opkssh); there is no sudo and no setuid
# escalation surface (see data/images/opencode/Dockerfile §5h).
#
# sshd lets you SSH straight into THIS container (authenticated by Zitadel
# via opkssh's AuthorizedKeysCommand), instead of landing in the tailscale
# sidecar that `tailscale ssh` would hit. opencode stays the foreground
# process so kubelet's :4096 probes govern pod liveness exactly as before.
set -eu

RUN_UID=1001
RUN_GID=1001

SSHD_KEY_DIR=/home/user/.local/share/opencode/sshd
HOST_KEY="${SSHD_KEY_DIR}/ssh_host_ed25519_key"

# 1. Persist the sshd host key on the opencode-data PVC so it survives pod
#    restarts (otherwise every restart regenerates it -> client MITM
#    warnings and Zed ControlMaster churn).
mkdir -p "${SSHD_KEY_DIR}"
if [ ! -f "${HOST_KEY}" ]; then
  ssh-keygen -t ed25519 -N "" -f "${HOST_KEY}" >/dev/null
fi
# sshd rejects a group/world-readable private host key ("UNPROTECTED PRIVATE
# KEY FILE" -> no hostkeys -> exit). Force 0600 (re-asserted after the chown
# below). sshd runs as root, so owner doesn't matter to it.
chmod 600 "${HOST_KEY}"

# 2. Materialize /etc/opk from the ConfigMap mount. opkssh refuses to read
#    EITHER policy file unless it's mode 640 root:opksshuser (world-readable
#    644 is rejected as insecure). ConfigMap mounts are read-only root:root,
#    so copy the files out and fix ownership/perms on both.
if [ -d /etc/opk-src ]; then
  mkdir -p /etc/opk
  cp /etc/opk-src/providers /etc/opk/providers
  cp /etc/opk-src/auth_id   /etc/opk/auth_id
  chown root:opksshuser /etc/opk/providers /etc/opk/auth_id
  chmod 0640 /etc/opk/providers /etc/opk/auth_id
fi

# opkssh `verify` (runs as opksshuser) only logs when this file exists and is
# writable by it — pre-create it or rejects are silent. Truncated each boot;
# /var/log is on the container fs (not persisted), which is fine for a log.
install -o root -g opksshuser -m 660 /dev/null /var/log/opkssh.log

# 3. Hand the runtime-mounted dirs that `user` must write over to `user`.
#    These are k8s volume mounts (the opencode-data PVC + the podman
#    graphroot/runroot emptyDirs + the git-ssh emptyDir) that arrive
#    root-owned (fsGroup=0); uid 1001 cannot write them until chowned. Runs
#    every boot — self-healing across restarts/node migrations. The PVC
#    chown is O(files); if it ever gets slow, gate on a top-level owner check.
chown -R "${RUN_UID}:${RUN_GID}" \
  /home/user/.local/share/opencode \
  /home/user/working \
  /home/user/.local/share/containers \
  /run/containers \
  /home/user/.ssh 2>/dev/null || true
# Re-assert 0600 on the host key — the recursive chown above re-touched its
# dir, and sshd (started next) bails on a loose-perm key.
chmod 600 "${HOST_KEY}"

# 4. sshd in the background, as ROOT — reachable on the pod's tailnet IP via
#    the tailscale ingress sidecar (shared netns); the pod-network side stays
#    blocked by the netpol default-deny baseline. /run is a fresh tmpfs at
#    runtime, so recreate the privilege-separation dir sshd requires.
#    Non-fatal: sshd is auxiliary. If it can't start, opencode web (the
#    primary service + the :4096 liveness target) must still come up — don't
#    let an SSH problem crashloop the whole pod.
mkdir -p /run/sshd
/usr/sbin/sshd || echo "WARN: sshd failed to start; continuing without SSH" >&2

# 5. Drop to `user` and exec opencode in the foreground (PID-significant for
#    the liveness probe). setpriv (not su/runuser): a direct exec with no PAM
#    session and no intermediate process, so opencode is PID 1's direct
#    successor. CRITICAL: do NOT pass --no-new-privs — rootless podman's
#    setuid newuidmap/newgidmap helpers need privilege escalation to map the
#    subuid range; no_new_privs would neuter them. --init-groups sets `user`'s
#    supplementary groups from /etc/group (none privileged). HOME must be set
#    explicitly (setpriv does not).
export HOME=/home/user
exec setpriv --reuid="${RUN_UID}" --regid="${RUN_GID}" --init-groups --inh-caps=-all \
  opencode web --hostname 0.0.0.0 --port 4096 "$@"
