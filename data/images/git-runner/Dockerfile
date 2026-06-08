# Forgejo Actions runner with a Podman Docker-API socket.
#
# The container runs `forgejo-runner daemon` whose container.docker_host points
# at a `podman system service` socket. The pod is UNPRIVILEGED and podman runs
# ROOTLESS as the `runner` user (uid 1001): nested job containers get their own
# user namespace via the subuid/subgid ranges below, so container-root maps to
# an unprivileged host uid — never node root. See services/git-runner.tf.
#
# Built in-cluster by services/git-runner-jobs.tf (BuildKit). FROM lines and
# the forgejo-runner download route through the in-cluster mirrors / internet
# egress granted to the builder namespace.
#
# Why FROM fedora + a downloaded binary, NOT the official
# data.forgejo.org/forgejo/runner image: that image is Alpine and ships no
# container runtime — the docs run it alongside a separate docker:dind sidecar.
# We instead bake podman into the runner image and run it rootless.
#
# forgejo-runner uses Forgejo's version scheme (12.x). Download URL pattern is
# the one from the docs: code.forgejo.org/.../v${V}/forgejo-runner-${V}-linux-amd64.
FROM docker.io/library/fedora:43

ARG RUNNER_VERSION=12.10.2

# Podman runtime: crun + overlay; netavark/aardvark for container networking;
# pasta (passt) for rootless networking; fuse-overlayfs as the rootless overlay
# fallback. shadow-utils provides the setuid newuidmap/newgidmap that rootless
# userns mapping needs. jq/curl/git for the registration step and checkouts.
RUN dnf -y install --setopt=install_weak_deps=False \
      podman buildah crun \
      netavark aardvark-dns passt fuse-overlayfs \
      shadow-utils util-linux iptables-nft libcap \
      jq curl ca-certificates git tar gzip \
    && dnf clean all

RUN useradd --uid 1001 --create-home --shell /bin/bash runner

# Subordinate uid/gid ranges for rootless podman: each nested job container gets
# its own user namespace mapped into this range, so its "root" is an
# unprivileged host uid. 65536 is enough for images that switch to high UIDs.
# OVERWRITE (>) not append: Fedora's useradd already auto-assigns runner a
# subuid/subgid range, so `>>` left TWO entries → podman built a 2-range uid_map
# that newuidmap rejected ("write to uid_map failed: Operation not permitted").
# A single deterministic entry yields a single clean range.
RUN printf 'runner:100000:65536\n' > /etc/subuid \
 && printf 'runner:100000:65536\n' > /etc/subgid

# Rootless podman config (the entrypoint drops to uid 1001):
# - storage.conf: NATIVE overlay driver. Confirmed working rootless on this node
#   (kernel 7.0.9; graphroot is the emptyDir, which sits on the node's REAL fs —
#   not overlay — so it's a valid overlay backing, no overlay-on-overlay). overlay
#   SHARES layers instead of vfs's full-copy-per-layer, so heavy Rust CI images
#   don't balloon the graphroot emptyDir (vfs was evicting the pod at 40Gi). No
#   mount_program → no fuse-overlayfs, no /dev/fuse needed. If a future node/fs
#   ever refuses rootless overlay, fall back to driver = "vfs" (slower, bigger).
# - containers.conf: crun, netns=host. "host" here is the POD's netns (the
#   podman service runs rootless inside the pod), NOT the node's — so nested job
#   containers share the pod network instead of getting their own netns. This
#   avoids pasta/slirp4netns, which need /dev/net/tun (absent in an unprivileged
#   pod without a device plugin). Jobs reach the in-cluster registry/proxies via
#   the pod's egress + /etc/hosts (host_aliases); --add-host in config.yaml.tpl
#   is then belt-and-suspenders. The pod (rootless userns + netpols) is the
#   isolation boundary; inter-job netns isolation is intentionally traded away.
RUN mkdir -p /etc/containers \
 && printf '%s\n' \
      '[storage]' \
      'driver = "overlay"' \
      'graphroot = "/home/runner/.local/share/containers"' \
      'runroot = "/run/containers/storage"' \
      > /etc/containers/storage.conf \
 && printf '%s\n' \
      '[containers]' \
      '# Nested job containers share the pod netns (no pasta/slirp → no' \
      '# /dev/net/tun needed in this unprivileged pod). See the comment above.' \
      'netns = "host"' \
      '# Share the pod PID namespace too. With no new pidns, crun BIND-MOUNTS the' \
      '# existing /proc instead of mounting a fresh procfs — which an unprivileged' \
      '# pod cannot do over the locked masked-paths ("mount proc to proc:' \
      '# Operation not permitted"). The k8s-native alternative (procMount=Unmasked' \
      '# + hostUsers=false) is unsupported by the typed TF kubernetes_deployment.' \
      'pidns = "host"' \
      '' \
      '[engine]' \
      'runtime = "crun"' \
      '# No systemd user session / journald socket in the pod: use the cgroupfs' \
      '# manager and a file event logger so rootless podman does not fail trying' \
      '# to reach systemd/journald.' \
      'cgroup_manager = "cgroupfs"' \
      'events_logger = "file"' \
      > /etc/containers/containers.conf

# Pin the forgejo-runner release.
RUN curl -fsSL -o /usr/local/bin/forgejo-runner \
      "https://code.forgejo.org/forgejo/runner/releases/download/v${RUNNER_VERSION}/forgejo-runner-${RUNNER_VERSION}-linux-amd64" \
    && chmod 0755 /usr/local/bin/forgejo-runner

COPY register.sh /register.sh
COPY register-init.sh /register-init.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /register.sh /register-init.sh /entrypoint.sh

# Generic setuid hardening — strip the setuid BIT broadly, then grant the two
# rootless-podman helpers FILE CAPABILITIES instead. newuidmap/newgidmap write
# the nested-container uid/gid range mapping, which needs CAP_SETUID/SETGID.
# The Fedora binaries ship with only the setuid bit, but in this unprivileged
# pod the setuid-root→capabilities legacy fixup does NOT fire (newuidmap runs
# euid 0 yet without CAP_SETUID → "write to uid_map failed: Operation not
# permitted", even with SELinux permissive). File caps (+ep) grant CAP_SETUID
# directly on exec, pulled from the bounding set (which already has it), so
# newuidmap runs at uid 1001 WITH CAP_SETUID and the write succeeds. They only
# authorize mapping IDs within the runner's /etc/sub{u,g}id allowance, so this
# is not a path to node root. Requires NoNewPrivs=0 (allow_privilege_escalation
# = true in the pod spec) for file caps to apply.
RUN find / -xdev -perm -4000 -type f -exec chmod u-s {} + 2>/dev/null || true \
 && setcap cap_setuid+ep /usr/bin/newuidmap \
 && setcap cap_setgid+ep /usr/bin/newgidmap \
 && getcap /usr/bin/newuidmap /usr/bin/newgidmap

ENTRYPOINT ["/entrypoint.sh"]
