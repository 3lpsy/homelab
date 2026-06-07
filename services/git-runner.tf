# Forgejo Actions runner (GitHub-Actions-equivalent CI for the Forgejo forge).
#
# Single pod in the `git` namespace. The main container runs a rootless
# podman Docker-API socket + `forgejo-runner daemon`; workflow jobs run in
# unprivileged podman containers (no privileged DinD) — same rootless stack
# as opencode (project_opencode_rootless_podman). NOT on the tailnet: the
# runner only dials out (Forgejo API + registries), so there's no headscale
# user, ACL, nginx, or Tailscale sidecar.
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
# Cross-referenced against https://forgejo.org/docs/latest/admin/actions/security/:
#   ✓ privileged=false + rootless podman (no "act as root on the runner")
#   ✓ container.network="" (fresh isolated network per job; not host/bridge)
#   ✓ runner.timeout bounded; per-job --memory/--cpus (see config.yaml.tpl)
#   ✓ admin cred isolated to the init container; .runner is NOT in
#     valid_volumes, so jobs can't read the runner token
#   ✓ instance already locks down Mallory: app.ini DISABLE_REGISTRATION=true
#     + REQUIRE_SIGNIN_VIEW=true (no anonymous accounts)
#   ~ Scope is USER-level (covers all your repos), not the docs' tightest
#     repo-level — a deliberate choice (AskUserQuestion). Re-register
#     repo-scoped if you want minimal blast radius.
#   ~ NOT ephemeral: this is a persistent `daemon` (k8s Deployment), not
#     `forgejo-runner one-job --ephemeral`. The docs prefer ephemeral so a
#     job can't reuse the runner; persistent is the pragmatic k8s choice for
#     a single-user homelab. The ambient registry cred (dedicated
#     `forgejo-runner` user) IS readable by any job (valid_volumes) — fine
#     while the runner only serves your own repos; reconsider if you ever run
#     untrusted/fork-PR workflows here (scope the registry user tighter).

locals {
  git_runner_image = "${local.thunderbolt_registry}/git-runner:latest"

  git_runner_dockerio_fqdn = "${var.registry_dockerio_domain}.${local.magic_fqdn_suffix}"
  git_runner_ghcrio_fqdn   = "${var.registry_ghcrio_domain}.${local.magic_fqdn_suffix}"
  git_runner_npm_fqdn      = "${var.npm_domain}.${local.magic_fqdn_suffix}"
  git_runner_crates_fqdn   = "${var.crates_domain}.${local.magic_fqdn_suffix}"

  # Default job images are pulled (by the podman service, in the runner pod
  # netns) through the in-cluster ghcr.io mirror.
  git_runner_labels = join(",", [
    "ubuntu-latest:docker://${local.git_runner_ghcrio_fqdn}/catthehacker/ubuntu:act-22.04",
    "ubuntu-22.04:docker://${local.git_runner_ghcrio_fqdn}/catthehacker/ubuntu:act-22.04",
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
# caches). Same shape as opencode_podman_registries.
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

# ─── PVC (.runner file + act cache) ──────────────────────────────────────────
resource "kubernetes_persistent_volume_claim" "git_runner_data" {
  lifecycle {
    prevent_destroy = true
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

        # MUST run on artemis. Rootless nested podman (the whole point of this
        # runner) needs artemis's kernel 7.x — delphi, the control-plane node, is
        # held on an older kernel for the Coral gasket-dkms driver and the
        # rootless userns uid_map setup fails there ("newuidmap: write to uid_map
        # failed: Operation not permitted"). artemis carries gpu=true:NoSchedule,
        # so this needs BOTH the selector and the toleration — same as opencode
        # and the BuildKit builder (the other rootless-podman workloads).
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

        # ── Runner daemon + rootless podman (no admin cred mounted) ──
        container {
          name              = "git-runner"
          image             = local.git_runner_image
          image_pull_policy = "Always"

          # Rootless podman needs to set up a userns: allow_privilege_escalation
          # must stay true (newuidmap/newgidmap are setuid-root); seccomp
          # Unconfined for unshare(CLONE_NEWUSER). The image strips all other
          # setuid bits + has no sudo, so this can't become a root shell.
          # Per project_opencode_rootless_podman.
          security_context {
            privileged                 = false
            allow_privilege_escalation = true
            seccomp_profile {
              type = "Unconfined"
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
          # Rootless podman storage: graphroot on a DISK emptyDir (native
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
            size_limit = "40Gi"
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

  depends_on = [module.git_runner_build]
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
