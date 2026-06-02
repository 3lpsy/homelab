#!/bin/sh
# Materialize the Forgejo SSH key into /home/user/.ssh with the perms sshd
# enforces (0700 dir, 0600 priv), and write ~/.ssh/config so plain
# `git@${GIT_FQDN}` clones route to port 2222 (the rootless Forgejo
# container can't bind <1024).
#
# opencode runs as the unprivileged `user` (uid 1001), so the key and its
# dir are chowned to 1001:1001. This init container runs as root (busybox),
# so the chowns succeed. The uid MUST match the `user` created in
# data/images/opencode/Dockerfile (§1b).
#
# Source secrets: CSI-mounted at /mnt/secrets by the kubelet from Vault
# (key opencode/config:git_ssh_priv + git_ssh_pub).
#
# Inputs (env):
#   GIT_FQDN   — fully-qualified Forgejo hostname (e.g. git.<magic>).
#                Pinned to the Forgejo Service ClusterIP via host_aliases
#                on the pod, so the in-cluster path doesn't need DNS.

set -eu

: "${GIT_FQDN:?GIT_FQDN env var is required}"

UID_USER=1001
GID_USER=1001

install -d -m 0700 /home/user/.ssh
install -m 0600 /mnt/secrets/git_ssh_priv /home/user/.ssh/id_ed25519
install -m 0644 /mnt/secrets/git_ssh_pub  /home/user/.ssh/id_ed25519.pub

cat > /home/user/.ssh/config <<EOF
Host $GIT_FQDN
  HostName $GIT_FQDN
  Port 2222
  User git
  IdentityFile /home/user/.ssh/id_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  UserKnownHostsFile /home/user/.ssh/known_hosts
EOF

chmod 0644 /home/user/.ssh/config
touch /home/user/.ssh/known_hosts
chmod 0644 /home/user/.ssh/known_hosts

# Hand the whole dir to `user` so the dropped opencode process can read the
# key (busybox runs as root, so chown works).
chown -R "${UID_USER}:${GID_USER}" /home/user/.ssh
