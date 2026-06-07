# Forgejo Actions runner with a rootless Podman Docker-API socket.
#
# The container runs `forgejo-runner daemon` whose container.docker_host
# points at a rootless `podman system service` socket — so workflow jobs run
# in unprivileged podman containers (no privileged DinD). Same rootless
# stack proven by the opencode pod on this k3s (kernel 7.x native overlay,
# no seccomp, no k3s-selinux). See project_opencode_rootless_podman.
#
# Built in-cluster by services/git-runner-jobs.tf (BuildKit). FROM lines and
# the forgejo-runner download route through the in-cluster mirrors / internet
# egress granted to the builder namespace.
#
# Why FROM fedora + a downloaded binary, NOT the official
# data.forgejo.org/forgejo/runner image: that image is Alpine and ships no
# container runtime — the docs run it alongside a privileged docker:dind
# sidecar. We instead bake a rootless podman Docker-API socket (no privilege),
# which is far smoother on Fedora's podman/crun/fuse-overlayfs stack (the same
# stack the opencode pod proved on this k3s).
#
# forgejo-runner uses Forgejo's version scheme (12.x). Download URL pattern is
# the one from the docs: code.forgejo.org/.../v${V}/forgejo-runner-${V}-linux-amd64.
FROM docker.io/library/fedora:43

ARG RUNNER_VERSION=12.10.2

# Rootless podman runtime: crun + fuse-overlayfs fallback + pasta/slirp4netns
# networking + netavark/aardvark for the job bridge network. jq/curl/git for
# the registration step and checkouts.
RUN dnf -y install --setopt=install_weak_deps=False \
      podman buildah crun fuse-overlayfs slirp4netns passt \
      netavark aardvark-dns shadow-utils util-linux iptables-nft \
      jq curl ca-certificates git tar gzip \
    && dnf clean all

# Unprivileged runner user (uid 1001, matches the opencode convention) with
# subuid/subgid ranges so rootless podman can map a userns.
RUN useradd --uid 1001 --create-home --shell /bin/bash runner \
    && echo 'runner:100000:65536' > /etc/subuid \
    && echo 'runner:100000:65536' > /etc/subgid

# Pin the forgejo-runner release.
RUN curl -fsSL -o /usr/local/bin/forgejo-runner \
      "https://code.forgejo.org/forgejo/runner/releases/download/v${RUNNER_VERSION}/forgejo-runner-${RUNNER_VERSION}-linux-amd64" \
    && chmod 0755 /usr/local/bin/forgejo-runner

COPY register.sh /register.sh
COPY register-init.sh /register-init.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /register.sh /register-init.sh /entrypoint.sh

# Strip setuid bits everywhere EXCEPT newuidmap/newgidmap (rootless podman
# needs those to write the userns uid/gid maps), then FORCE the setuid bit on
# those two.
#
# Why force it: Fedora ships newuidmap/newgidmap (/usr/sbin) with file
# capabilities (cap_setuid+ep), NOT the setuid bit. Rootless podman extracting
# this image into its graphroot can't apply the `security.capability` xattr (that
# needs CAP_SETFCAP), so the caps are dropped and the helpers end up unprivileged
# → "newuidmap: write to uid_map failed: Operation not permitted ... should have
# setuid or have filecaps setuid". The setuid BIT is a plain mode bit that DOES
# survive extraction; with allow_privilege_escalation=true it runs as userns-root
# and can write the map. This is how the Debian-based opencode image works (its
# uidmap package ships these setuid at /usr/bin).
RUN find / -xdev -perm -4000 -type f \
      ! -name newuidmap ! -name newgidmap -exec chmod u-s {} + 2>/dev/null || true \
 && for b in newuidmap newgidmap; do chmod u+s "$(command -v "$b")"; done

ENTRYPOINT ["/entrypoint.sh"]
