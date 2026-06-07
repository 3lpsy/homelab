# forgejo-runner (act_runner) config. Rendered by services/git-runner.tf via
# templatefile(). Only $${...} interpolations are TF vars — there is no shell
# in this file.
#
# Builds run via a rootless podman Docker-API socket (container.docker_host),
# so jobs are unprivileged. The container.options below are the crux of
# in-cluster registry/proxy access: job containers get their OWN netns and
# /etc/hosts, so they do NOT inherit the runner pod's host_aliases. The
# --add-host flags pin each registry/proxy FQDN to its Service ClusterIP
# inside every job container, and the -v mounts inject the ambient registry
# push credential + npm/cargo proxy config. Base-image pulls (handled by the
# podman service in the runner pod netns) instead use the pod host_aliases +
# the registries.conf mirror drop-in.
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
  # "" = a fresh ISOLATED network per job (the safe default per the Forgejo
  # security docs). NOT "host" (frees jobs to reach the host/pod-local
  # services) and NOT "bridge" (shared, unrestricted between job containers).
  network: ""
  # MUST stay false. true = a malicious workflow runs as root on the runner
  # (Forgejo security docs). Rootless podman gives us isolation without it.
  privileged: false
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
  # --memory/--cpus bound each job (docs recommend explicit limits). Sized to
  # fit the runner pod's cgroup (capacity 2 × 4g/3cpu ≤ pod 12Gi/6cpu). Needs
  # rootless cgroup-v2 delegation to enforce; harmless (warn-only) without it.
  options: >-
    --memory=4g
    --cpus=3
    --add-host=${registry_fqdn}:${registry_cluster_ip}
    --add-host=${registry_dockerio_fqdn}:${registry_dockerio_cluster_ip}
    --add-host=${registry_ghcrio_fqdn}:${registry_ghcrio_cluster_ip}
    --add-host=${npm_fqdn}:${npm_cluster_ip}
    --add-host=${crates_fqdn}:${crates_cluster_ip}
    -v /etc/ci-auth/config.json:/root/.docker/config.json:ro
    -v /etc/ci-npm/.npmrc:/root/.npmrc:ro
    -v /etc/ci-cargo/config.toml:/root/.cargo/config.toml:ro
