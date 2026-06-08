# CI job image for the Forgejo Actions runner: podman-in-podman + Node for JS
# actions (actions/checkout et al.). Selected via the `ci-podman` runner label
# (services/git-runner.tf) — replaces the upstream catthehacker image (only
# official bases + this self-built image now).
#
# Runs PRIVILEGED inside the ROOTLESS git-runner pod. "privileged" here means
# privileged WITHIN the runner's user namespace (the job container is created by
# the runner's rootless podman), so the job's root maps to an unprivileged host
# uid — NOT node root. Node isolation stays with the rootless runner; privileged
# just lets the nested podman set up its own userns/overlay/proc the standard
# podman-in-podman way (config.yaml.tpl sets container.privileged: true).
#
# Built in-cluster by services/git-runner-jobs.tf (BuildKit) and pushed to the
# in-cluster registry; the runner pulls it via REGISTRY_AUTH_FILE.
FROM quay.io/podman/stable

# quay.io/podman/stable (official, Fedora-based) already ships podman + crun +
# fuse-overlayfs + a PinP-tuned containers.conf + subuid/subgid for its user.
# Add only what JS-action CI needs:
#   - nodejs: forgejo-runner execs `node` to run JS actions (actions/checkout).
#   - git:    checkout's git operations.
#   - tar/gzip: act's cache + checkout archive handling. ca-certificates: TLS.
RUN dnf -y install --setopt=install_weak_deps=False \
      nodejs git tar gzip ca-certificates \
    && dnf clean all

# Override quay/stable's rootless storage.conf (which sets
# mount_program=fuse-overlayfs → needs /dev/fuse, absent in this pod) with
# NATIVE kernel overlay. Safe + correct here: the job runs PRIVILEGED so its
# podman has CAP_SYS_ADMIN to mount overlay, and the git-runner uses VFS storage
# so the job's rootfs (hence /var/lib/containers/storage) lands on the node's
# real fs — overlay is NOT stacked on overlay. No mount_program = no fuse.
# (If native overlay ever errors, change driver to "vfs" here — slower but needs
# nothing.)
RUN printf '%s\n' \
      '[storage]' \
      'driver = "overlay"' \
      'runroot = "/run/containers/storage"' \
      'graphroot = "/var/lib/containers/storage"' \
      > /etc/containers/storage.conf

# NOTE: nested `podman run` of a FULL container inside this (rootful, privileged)
# job does not work in this pod — it needs both a fresh /proc mount (blocked by
# the pod's locked masked-paths) and a cgroup (no delegation here), which are
# mutually exclusive without procMount:Unmasked+hostUsers:false (TF provider
# can't set them) or systemd cgroup delegation (absent). So workflows must NOT
# `podman run` test/service containers here; run such images as the forgejo job's
# `container:` instead (the runner's ROOTLESS podman handles those fine). Nested
# `podman build` IS fine (buildah uses chroot isolation — no /proc, no cgroup),
# and its RUN steps reach the in-cluster proxies via the job's (pod) netns.
