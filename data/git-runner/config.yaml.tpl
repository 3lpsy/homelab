# forgejo-runner (act_runner) config. Rendered by services/git-runner.tf via
# templatefile(). Only $${...} interpolations are TF vars — there is no shell
# in this file.
#
# Builds run via a rootless podman Docker-API socket (container.docker_host),
# so jobs are unprivileged. The container.options below are the crux of
# in-cluster access: even though jobs SHARE the runner pod's netns (network:
# host), podman gives each job container its OWN /etc/hosts, so they do NOT
# inherit the runner pod's host_aliases. The --add-host flags pin each
# in-cluster FQDN to its Service ClusterIP inside every job container:
#   - git: so `actions/checkout` (https://git.<magic>) reaches Forgejo's
#     ClusterIP instead of the unroutable tailnet IP (otherwise the fetch
#     times out);
#   - registry/proxies: for image push + npm/cargo proxy access.
# The -v mounts inject, into every job: the ambient registry push credential
# (/root/.docker/config.json — podman reads it for in-cluster registry push/pull),
# the npm + cargo proxy configs, AND the podman registries.conf mirror drop-in so
# the JOB's own `podman build` pulls docker.io/ghcr.io base images through the
# in-cluster proxies (gated + rate-limit-free) too — not just the runner's pulls.
# All proxy/registry FQDNs resolve via the --add-host pins above; egress is
# allowed by the git_runner_to_registry{,_proxy} NetworkPolicies.
log:
  level: info

runner:
  file: /data/.runner          # persisted on the PVC → register once
  capacity: 2                  # concurrent jobs
  timeout: 3h
  fetch_timeout: 5s
  fetch_interval: 2s
  # Labels are set at registration time via `forgejo-runner register --labels`
  # (see register.sh); left empty here so the .runner file stays authoritative.
  labels: []

cache:
  enabled: true
  dir: /data/cache

container:
  # "host" = the POD's netns (the runner is rootless inside an unprivileged
  # pod), NOT the node's. We can't use "" (isolated per-job network) because
  # rootless netavark/pasta needs /dev/net/tun, which an unprivileged pod lacks
  # (no device plugin). Sharing the pod netns avoids the tap device entirely;
  # the pod's rootless userns + the git-runner NetworkPolicies remain the
  # isolation boundary, and jobs reach the in-cluster registry/proxies through
  # the pod's egress. Trade-off: concurrent jobs share one netns (fine for a
  # single-user CI). The Forgejo docs warn against host-net on a bare-metal
  # runner (where host = the machine); here host = an already-fenced pod.
  network: "host"
  # Always re-pull the job image. It's a mutable :latest in the in-cluster
  # registry (rebuilt by BuildKit when data/images/ci-podman/Dockerfile changes),
  # so force_pull ensures each job uses the current build instead of a stale
  # cached layer. Cheap — the pull is intra-cluster.
  force_pull: true
  # privileged: true — SAFE here because the RUNNER is rootless. The runner's
  # rootless podman creates each job container, so a "privileged" job is
  # privileged only WITHIN the runner's user namespace: its root maps to an
  # unprivileged host uid, NOT node root. Node isolation stays with the rootless
  # runner; privileged just lets the job's nested podman set up its own
  # userns/overlay/proc the standard podman-in-podman way (the `ci-podman` job
  # image). (The old "MUST stay false" rule applied to the previous ROOTFUL
  # runner, where privileged == node root — no longer the case.) It does grant a
  # job broad control WITHIN the runner pod, so keep this runner user-scoped:
  # do NOT point it at untrusted/fork-PR workflows.
  privileged: true
  docker_host: unix:///run/podman/podman.sock
  # SECURITY TRADEOFF (Forgejo security docs): anything in valid_volumes is
  # readable by every job — so the registry push cred mounted below is NOT
  # confidential from workflow code. This is the cost of "no per-repo secret":
  # acceptable here because the runner is user-scoped (only your repos) and the
  # registry cred is the dedicated `forgejo-runner` user (isolated from
  # `internal` + independently rotatable). If you ever accept untrusted/fork
  # PRs on this runner, revisit this (scope the registry user tighter).
  valid_volumes:
    - /etc/ci-auth/config.json
    - /etc/ci-npm/.npmrc
    - /etc/ci-cargo/config.toml
    - /etc/containers/registries.conf.d/01-homelab-mirrors.conf
    # Persistent incremental build cache on the runner's /data PVC, shared
    # READ-WRITE across jobs as /cache. The dev-release pipeline points
    # CARGO_HOME/CARGO_TARGET_DIR here (only changed crates recompile) and hands
    # the staged binary between its build + image jobs via /cache/staging.
    - /data/build-cache
  # --memory/--cpus bound each job (docs recommend explicit limits). Sized to
  # fit the runner pod's cgroup (capacity 2 × 4g/3cpu ≤ pod 12Gi/6cpu). Needs
  # rootless cgroup-v2 delegation to enforce; harmless (warn-only) without it.
  options: >-
    --memory=4g
    --cpus=3
    --add-host=${git_fqdn}:${git_cluster_ip}
    --add-host=${registry_fqdn}:${registry_cluster_ip}
    --add-host=${registry_dockerio_fqdn}:${registry_dockerio_cluster_ip}
    --add-host=${registry_ghcrio_fqdn}:${registry_ghcrio_cluster_ip}
    --add-host=${npm_fqdn}:${npm_cluster_ip}
    --add-host=${crates_fqdn}:${crates_cluster_ip}
    -v /etc/ci-auth/config.json:/root/.docker/config.json:ro
    -v /etc/ci-npm/.npmrc:/root/.npmrc:ro
    -v /etc/ci-cargo/config.toml:/root/.cargo/config.toml:ro
    -v /etc/containers/registries.conf.d/01-homelab-mirrors.conf:/etc/containers/registries.conf.d/01-homelab-mirrors.conf:ro
    -v /data/build-cache:/cache
