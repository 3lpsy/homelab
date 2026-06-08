# Forgejo Actions runner (GitHub-Actions-equivalent CI for the Forgejo forge).
#
# Single pod in the `git` namespace. The main container runs a podman
# Docker-API socket + `forgejo-runner daemon` as the unprivileged `runner` user
# (uid 1001) — ROOTLESS podman in an UNPRIVILEGED pod. Nested job containers run
# in a further user namespace (subuid/subgid 100000:65536), so "root" inside any
# job maps to an unprivileged host uid, NOT node root: a malicious CI dependency
# that gains container-root cannot pivot to compromise artemis. Same isolation
# model as the rootless BuildKit `builder`. Mitigations stack: user-scoped runner
# (only your repos), pinned to artemis, fenced by NetworkPolicies, and the admin
# cred is isolated to the init container. NOT on the tailnet: the runner only
# dials out (Forgejo API + registries), so there's no headscale user, ACL,
# nginx, or Tailscale sidecar.
#
# Registration is user-scoped and automatic: an init container mints a
# user-scoped registration token (gitadmin + `Sudo:` header) and writes
# /data/.runner. The admin credential lives ONLY in that init container, so
# the long-running, workflow-executing container never holds it.
#
# Secrets model (see also the ambient registry cred below): pushing to the
# in-cluster registry is INFRASTRUCTURE, identical for every repo, so it's
# baked into the runner (a dedicated `forgejo-runner` registry user injected
# into every job via container.options) — repo workflows push with NO secret.
# Per-repo external creds belong in repo-level Forgejo secrets.
#
# Security notes (https://forgejo.org/docs/latest/admin/actions/security/):
#   - The pod is UNPRIVILEGED + rootless (see the container security_context).
#     Container-root != node-root via the userns mapping; blast radius is further
#     bounded by user-scoped registration, artemis-only scheduling, NetworkPolicies,
#     and the admin cred isolated to the init container (.runner is not in
#     valid_volumes).
#   - Scope is USER-level (covers all your repos), not the docs' tightest
#     repo-level — a deliberate choice. Re-register repo-scoped to minimize it.
#   - NOT ephemeral: persistent `daemon` (k8s Deployment). The ambient registry
#     cred (dedicated `forgejo-runner` user) IS readable by any job — fine while
#     the runner only serves your own repos. Rootless reduces but does not erase
#     this risk: do NOT point this runner at untrusted/fork-PR workflows.

locals {
  git_runner_image = "${local.thunderbolt_registry}/git-runner:latest"
  # CI job image (the `ci-podman` label) — self-built podman+Node image in the
  # in-cluster registry, replacing upstream catthehacker. Built by
  # services/git-runner-jobs.tf.
  ci_podman_image = "${local.thunderbolt_registry}/ci-podman:latest"

  git_runner_dockerio_fqdn = "${var.registry_dockerio_domain}.${local.magic_fqdn_suffix}"
  git_runner_ghcrio_fqdn   = "${var.registry_ghcrio_domain}.${local.magic_fqdn_suffix}"
  git_runner_npm_fqdn      = "${var.npm_domain}.${local.magic_fqdn_suffix}"
  git_runner_crates_fqdn   = "${var.crates_domain}.${local.magic_fqdn_suffix}"

  # Single label `ci-podman` → our self-built podman+Node job image in the
  # in-cluster registry (only official bases / images we build; no catthehacker).
  # The runner's podman pulls it authenticated (REGISTRY_AUTH_FILE on the runner
  # container) over the existing netpol egress to the registry ns. Workflows use
  # `runs-on: ci-podman`.
  git_runner_labels = join(",", [
    "ci-podman:docker://${local.ci_podman_image}",
  ])
}

resource "kubernetes_service_account" "git_runner" {
  metadata {
    name      = "git-runner"
    namespace = kubernetes_namespace.git.metadata[0].name
  }
  # The runner talks to Forgejo + registries, never the kube API.
  automount_service_account_token = false
}

# ─── Ambient registry credential ─────────────────────────────────────────────
# Dual purpose: (1) kubelet imagePullSecret for the runner's own image, and
# (2) bind-mounted into every workflow job at /root/.docker/config.json so
# `docker push registry.<magic>/...` is pre-authenticated. Uses the dedicated
# `forgejo-runner` registry user (in var.registry_users) so the CI cred is
# isolated from `internal` and rotates independently:
#   ./terraform.sh services apply -replace='random_password.registry_user_passwords["forgejo-runner"]'
# (Adding this user now propagates correctly — the registry htpasswd is no longer
# frozen by ignore_changes; see the {SHA} note in services/registry.tf.)
resource "kubernetes_secret" "git_runner_registry_auth" {
  metadata {
    name      = "git-runner-registry-auth"
    namespace = kubernetes_namespace.git.metadata[0].name
  }
  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${local.thunderbolt_registry}" = {
          username = "forgejo-runner"
          password = random_password.registry_user_passwords["forgejo-runner"].result
          auth     = base64encode("forgejo-runner:${random_password.registry_user_passwords["forgejo-runner"].result}")
        }
      }
    })
  }
}

# gitadmin password for the registration init container only. Derived from the
# same random_password that git.tf already writes to Vault (Vault stays the
# source of truth); a plain k8s Secret here mirrors builder-secrets.tf and
# avoids issuing a spurious ACME cert just to use the Vault-CSI path. Rotation
# follows the gitadmin rotation in git.tf.
resource "kubernetes_secret" "git_runner_admin" {
  metadata {
    name      = "git-runner-admin"
    namespace = kubernetes_namespace.git.metadata[0].name
  }
  data = {
    forgejo_admin_password = random_password.git_admin_password.result
  }
}

# ─── ConfigMaps ──────────────────────────────────────────────────────────────
resource "kubernetes_config_map" "git_runner_config" {
  metadata {
    name      = "git-runner-config"
    namespace = kubernetes_namespace.git.metadata[0].name
  }
  data = {
    "config.yaml" = templatefile("${path.module}/../data/git-runner/config.yaml.tpl", {
      git_fqdn                     = local.git_fqdn
      git_cluster_ip               = kubernetes_service.git.spec[0].cluster_ip
      registry_fqdn                = local.thunderbolt_registry
      registry_cluster_ip          = kubernetes_service.registry.spec[0].cluster_ip
      registry_dockerio_fqdn       = local.git_runner_dockerio_fqdn
      registry_dockerio_cluster_ip = kubernetes_service.registry_dockerio.spec[0].cluster_ip
      registry_ghcrio_fqdn         = local.git_runner_ghcrio_fqdn
      registry_ghcrio_cluster_ip   = kubernetes_service.registry_ghcrio.spec[0].cluster_ip
      npm_fqdn                     = local.git_runner_npm_fqdn
      npm_cluster_ip               = kubernetes_service.npm.spec[0].cluster_ip
      crates_fqdn                  = local.git_runner_crates_fqdn
      crates_cluster_ip            = kubernetes_service.crates.spec[0].cluster_ip
    })
  }
}

# Podman mirror drop-in for the runner pod (base-image pulls → in-cluster
# caches).
resource "kubernetes_config_map" "git_runner_registries" {
  metadata {
    name      = "git-runner-registries"
    namespace = kubernetes_namespace.git.metadata[0].name
  }
  data = {
    "01-homelab-mirrors.conf" = <<-EOT
      unqualified-search-registries = ["docker.io"]

      [[registry]]
      prefix = "docker.io"
      location = "docker.io"
      [[registry.mirror]]
      location = "${local.git_runner_dockerio_fqdn}"

      [[registry]]
      prefix = "ghcr.io"
      location = "ghcr.io"
      [[registry.mirror]]
      location = "${local.git_runner_ghcrio_fqdn}"
    EOT
  }
}

# Ambient npm + cargo config injected into every job (read-access to the
# cooldown proxies). Same forms as opencode / docs/DEP_SAFETY.md.
resource "kubernetes_config_map" "git_runner_ci_npm" {
  metadata {
    name      = "git-runner-ci-npm"
    namespace = kubernetes_namespace.git.metadata[0].name
  }
  data = {
    ".npmrc" = "registry=https://${local.git_runner_npm_fqdn}/\n"
  }
}

resource "kubernetes_config_map" "git_runner_ci_cargo" {
  metadata {
    name      = "git-runner-ci-cargo"
    namespace = kubernetes_namespace.git.metadata[0].name
  }
  data = {
    "config.toml" = <<-EOT
      [source.crates-io]
      replace-with = "homelab"

      [source.homelab]
      registry = "sparse+https://${local.git_runner_crates_fqdn}/index/"
    EOT
  }
}

# ─── PVC (.runner file + act cache + /data/build-cache) ──────────────────────
# The pod runs rootless as uid 1001; the pod-level fs_group=1001 makes this
# local-path PV (otherwise root-owned) writable by the runner. Also holds
# /data/build-cache, bind-mounted into every job at /cache for the dev-release
# incremental CARGO_HOME/CARGO_TARGET_DIR + staged-binary handoff (see
# config.yaml.tpl + the entrypoint mkdir/chmod). (Image storage/graphroot stays
# on a separate emptyDir, NOT this PVC: overlay can't stack on local-path.)
resource "kubernetes_persistent_volume_claim" "git_runner_data" {
  lifecycle {
    prevent_destroy = true
    # local-path's StorageClass has no allowVolumeExpansion, so resizing an
    # EXISTING PVC is rejected by the API. Ignore request changes so bumping
    # var.git_runner_storage_size only affects FRESH provisions and never errors
    # an apply on the live PVC. NOTE: local-path doesn't enforce the size anyway —
    # the build-cache grows on artemis's real disk (no PVC-size eviction, unlike
    # the emptyDir graphroot); the number is nominal. Watch the node's disk.
    ignore_changes = [spec[0].resources[0].requests]
  }
  metadata {
    name      = "git-runner-data"
    namespace = kubernetes_namespace.git.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.git_runner_storage_size
      }
    }
  }
  wait_until_bound = false
}

# ─── Deployment ──────────────────────────────────────────────────────────────
resource "kubernetes_deployment" "git_runner" {
  metadata {
    name      = "git-runner"
    namespace = kubernetes_namespace.git.metadata[0].name
    labels    = { app = "git-runner" }
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate" # RWO PVC + a single registered runner identity
    }
    selector {
      match_labels = { app = "git-runner" }
    }

    template {
      metadata {
        labels = { app = "git-runner" }
        annotations = {
          "config-hash" = sha1(jsonencode({
            cfg    = kubernetes_config_map.git_runner_config.data
            reg    = kubernetes_config_map.git_runner_registries.data
            npm    = kubernetes_config_map.git_runner_ci_npm.data
            cargo  = kubernetes_config_map.git_runner_ci_cargo.data
            labels = local.git_runner_labels
          }))
        }
      }

      spec {
        service_account_name = kubernetes_service_account.git_runner.metadata[0].name

        # Rootless pod. fs_group=1001 hands the local-path PVC + the podman
        # graphroot/runroot emptyDirs to the runner uid (they arrive root-owned).
        # seccomp Unconfined: rootless podman's userns setup (unshare/clone) +
        # nested-container mounts need syscalls a confined profile blocks — same
        # as the rootless BuildKit pod (templates/buildkit-job).
        security_context {
          fs_group = 1001
          seccomp_profile {
            type = "Unconfined"
          }
        }

        # Run on artemis (the compute node), alongside the BuildKit builder —
        # off delphi's user-facing services + its node-bound local-path PVCs.
        # artemis carries gpu=true:NoSchedule, so this needs BOTH the selector
        # and the toleration.
        node_selector = { node = "artemis" }
        toleration {
          key      = "gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        image_pull_secrets {
          name = kubernetes_secret.git_runner_registry_auth.metadata[0].name
        }

        # Forgejo (registration) + the registry/proxies (podman base-image
        # pulls). Pod-level → applies to init + main. FQDN→ClusterIP so TLS
        # SNI matches each nginx cert SAN.
        host_aliases {
          ip        = kubernetes_service.git.spec[0].cluster_ip
          hostnames = [local.git_fqdn]
        }
        host_aliases {
          ip        = kubernetes_service.registry.spec[0].cluster_ip
          hostnames = [local.thunderbolt_registry]
        }
        host_aliases {
          ip        = kubernetes_service.registry_dockerio.spec[0].cluster_ip
          hostnames = [local.git_runner_dockerio_fqdn]
        }
        host_aliases {
          ip        = kubernetes_service.registry_ghcrio.spec[0].cluster_ip
          hostnames = [local.git_runner_ghcrio_fqdn]
        }
        host_aliases {
          ip        = kubernetes_service.npm.spec[0].cluster_ip
          hostnames = [local.git_runner_npm_fqdn]
        }
        host_aliases {
          ip        = kubernetes_service.crates.spec[0].cluster_ip
          hostnames = [local.git_runner_crates_fqdn]
        }

        # ── Registration init container (holds the admin cred, then exits) ──
        init_container {
          name              = "register"
          image             = local.git_runner_image
          image_pull_policy = "Always"
          command           = ["/register-init.sh"]

          # Run as the runner uid so /data/.runner is owned 1001:1001 (matching
          # the main container, which must rewrite it). Pure curl/jq + a file
          # write — no setuid needed, so escalation stays off here.
          security_context {
            allow_privilege_escalation = false
            run_as_user                = 1001
            run_as_group               = 1001
            run_as_non_root            = true
          }

          env {
            name  = "GIT_FQDN"
            value = local.git_fqdn
          }
          env {
            name  = "PERSONAL_USER"
            value = var.zitadel_personal_user.user_name
          }
          env {
            name  = "RUNNER_FILE"
            value = "/data/.runner"
          }
          env {
            name  = "RUNNER_LABELS"
            value = local.git_runner_labels
          }

          volume_mount {
            name       = "runner-data"
            mount_path = "/data"
          }
          volume_mount {
            name       = "config"
            mount_path = "/config/config.yaml"
            sub_path   = "config.yaml"
            read_only  = true
          }
          volume_mount {
            name       = "admin-secret"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # ── Runner daemon + podman (no admin cred mounted) ──
        container {
          name              = "git-runner"
          image             = local.git_runner_image
          image_pull_policy = "Always"

          # The runner pulls the `ci-podman` job image from the in-cluster
          # registry (authenticated, via the forgejo-runner registry user whose
          # dockerconfigjson is mounted at /etc/ci-auth/config.json). forgejo-
          # runner/act issues the pull over the Docker API and reads creds from
          # $DOCKER_CONFIG/config.json — NOT REGISTRY_AUTH_FILE (that's podman-CLI
          # only). So DOCKER_CONFIG is the one that actually authenticates the
          # job-image pull; REGISTRY_AUTH_FILE is kept for any direct podman CLI
          # use. Egress to the registry ns is allowed by git_runner_to_registry.
          env {
            name  = "DOCKER_CONFIG"
            value = "/etc/ci-auth"
          }
          env {
            name  = "REGISTRY_AUTH_FILE"
            value = "/etc/ci-auth/config.json"
          }

          # Rootless: the runner + its podman run as the unprivileged `runner`
          # user (uid 1001), and nested job containers get their own userns
          # (subuid/subgid baked in the image), so container-root maps to an
          # unprivileged host uid — never node root.
          # allow_privilege_escalation MUST stay true: rootless podman invokes
          # the setuid newuidmap/newgidmap helpers to write the nested-container
          # uid/gid range mapping; with NoNewPrivs on (escalation=false) they
          # fail ("newuidmap: write to uid_map failed"). This does NOT grant node
          # root — newuidmap only writes within the allowed subuid range.
          security_context {
            privileged                 = false
            allow_privilege_escalation = true
            run_as_user                = 1001
            run_as_group               = 1001
            run_as_non_root            = true
            # Keep SETUID/SETGID in the bounding set (they're in the default set
            # already; explicit = intent + guarantee). The ACTUAL fix for the
            # rootless userns mapping lives in the image: newuidmap/newgidmap are
            # given file capabilities (cap_setuid/setgid +ep) so they run with
            # CAP_SETUID at uid 1001 and can write the nested-container
            # uid_map/gid_map — the Fedora setuid-bit path does not grant caps in
            # this pod. File caps pull from THIS bounding set, and need
            # NoNewPrivs=0 (allow_privilege_escalation above) to apply. See
            # data/images/git-runner/Dockerfile. Not a path to node root: the
            # helpers only map IDs within the runner's /etc/sub{u,g}id range.
            capabilities {
              add = ["SETUID", "SETGID"]
            }
          }

          # Guarantee a full CPU + 4Gi floor; the heavy work (cargo-chef
          # compile, dx bundle, and the testing image's chromium e2e) runs as
          # podman sibling containers under THIS pod's cgroup (not the per-job
          # --memory cap) and bursts above the request up to the 12Gi limit.
          resources {
            requests = { cpu = "1", memory = "4Gi" }
            limits   = { cpu = "6", memory = "12Gi" }
          }

          volume_mount {
            name       = "runner-data"
            mount_path = "/data"
          }
          volume_mount {
            name       = "config"
            mount_path = "/config/config.yaml"
            sub_path   = "config.yaml"
            read_only  = true
          }
          # Podman storage: graphroot on a DISK emptyDir (native
          # overlay refuses an upperdir on the local-path PVC's overlay);
          # runroot on tmpfs; the Docker-API socket on a shared emptyDir.
          volume_mount {
            name       = "podman-graphroot"
            mount_path = "/home/runner/.local/share/containers"
          }
          volume_mount {
            name       = "podman-runroot"
            mount_path = "/run/containers"
          }
          volume_mount {
            name       = "podman-sock"
            mount_path = "/run/podman"
          }
          volume_mount {
            name       = "registries"
            mount_path = "/etc/containers/registries.conf.d/01-homelab-mirrors.conf"
            sub_path   = "01-homelab-mirrors.conf"
            read_only  = true
          }
          # Bind-mount sources for container.options (-v) injected into jobs.
          volume_mount {
            name       = "ci-auth"
            mount_path = "/etc/ci-auth"
            read_only  = true
          }
          volume_mount {
            name       = "ci-npm"
            mount_path = "/etc/ci-npm/.npmrc"
            sub_path   = ".npmrc"
            read_only  = true
          }
          volume_mount {
            name       = "ci-cargo"
            mount_path = "/etc/ci-cargo/config.toml"
            sub_path   = "config.toml"
            read_only  = true
          }
        }

        volume {
          name = "runner-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.git_runner_data.metadata[0].name
          }
        }
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.git_runner_config.metadata[0].name
          }
        }
        volume {
          name = "registries"
          config_map {
            name = kubernetes_config_map.git_runner_registries.metadata[0].name
          }
        }
        volume {
          name = "ci-npm"
          config_map {
            name = kubernetes_config_map.git_runner_ci_npm.metadata[0].name
          }
        }
        volume {
          name = "ci-cargo"
          config_map {
            name = kubernetes_config_map.git_runner_ci_cargo.metadata[0].name
          }
        }
        volume {
          name = "admin-secret"
          secret {
            secret_name = kubernetes_secret.git_runner_admin.metadata[0].name
          }
        }
        volume {
          name = "ci-auth"
          secret {
            secret_name = kubernetes_secret.git_runner_registry_auth.metadata[0].name
            items {
              key  = ".dockerconfigjson"
              path = "config.json"
            }
          }
        }
        volume {
          name = "podman-graphroot"
          empty_dir {
            # Runner podman image/layer storage. The runner is UNPRIVILEGED so it
            # uses the vfs driver (no overlay), which full-copies every layer —
            # heavy (Rust CI) images balloon here. 50Gi is headroom; the real
            # cure is getting the runner onto overlay (see storage.conf note in
            # data/images/git-runner/Dockerfile). Bump higher if builds still
            # evict — artemis has the disk.
            size_limit = "50Gi"
          }
        }
        volume {
          name = "podman-runroot"
          empty_dir {
            medium = "Memory"
          }
        }
        volume {
          name = "podman-sock"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [module.git_runner_build, module.ci_podman_build]
}

# ─── NetworkPolicies ─────────────────────────────────────────────────────────
# The `git` ns baseline (git_netpol_baseline in git.tf) already provides
# default-deny + intra-ns (runner → Forgejo) + DNS + internet egress (for
# `uses:` action fetch from code.forgejo.org). These add the cross-ns allows
# for registry push + proxy pulls. Scoped to app=git-runner per
# feedback_netpol_least_privilege; egress + matching ingress per the repo's
# cross-ns convention.

resource "kubernetes_network_policy" "git_runner_to_registry" {
  metadata {
    name      = "git-runner-to-registry"
    namespace = kubernetes_namespace.git.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = { app = "git-runner" }
    }
    policy_types = ["Egress"]
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = kubernetes_namespace.registry.metadata[0].name }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

resource "kubernetes_network_policy" "git_runner_to_registry_proxy" {
  metadata {
    name      = "git-runner-to-registry-proxy"
    namespace = kubernetes_namespace.git.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = { app = "git-runner" }
    }
    policy_types = ["Egress"]
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = kubernetes_namespace.registry_proxy.metadata[0].name }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

# Matching ingress on the destination namespaces.
resource "kubernetes_network_policy" "registry_from_git_runner" {
  metadata {
    name      = "registry-from-git-runner"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress"]
    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = kubernetes_namespace.git.metadata[0].name }
        }
        pod_selector {
          match_labels = { app = "git-runner" }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

resource "kubernetes_network_policy" "registry_proxy_from_git_runner" {
  metadata {
    name      = "registry-proxy-from-git-runner"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress"]
    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = kubernetes_namespace.git.metadata[0].name }
        }
        pod_selector {
          match_labels = { app = "git-runner" }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}
