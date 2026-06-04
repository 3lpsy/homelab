# BuildKit + seed Jobs for Jellyfin.
#
# 1. `module.jellyfin_build` — rebuilds the custom Jellyfin image (upstream
#    + 9p4/jellyfin-plugin-sso) on Dockerfile / plugin-version change. The
#    Deployment's container references `local.jellyfin_image` which
#    matches the BuildKit push target.
#
# 2. `kubernetes_job.jellyfin_seed` — Python stdlib-only reconcile Job
#    that drives Jellyfin's HTTP API to:
#      - finish the first-run startup wizard with a hidden `_seed` admin
#      - create personal + partner local users (passwordless — OIDC +
#        Quick Connect are the only login paths)
#      - configure the SSO plugin against Zitadel via
#        POST /sso/OID/Add/zitadel
#      - ensure Quick Connect is server-side enabled
#    Hash-gated per-section (state cached at /jf-config/seed/state.json on
#    the shared jellyfin-config PVC — must NOT be at PVC root or with a
#    `.jellyfin-` prefix; newer Jellyfin sanity-rejects unknown markers
#    there), so a steady-state re-apply is a no-op.

module "jellyfin_build" {
  source = "./../templates/buildkit-job"

  name      = "jellyfin"
  image_ref = local.jellyfin_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/jellyfin/Dockerfile")
  }

  # Plugin version + upstream image both flow through as build args. Any
  # change to either rolls a new image hash → BuildKit re-runs.
  build_args = {
    BASE_IMAGE         = var.image_jellyfin_upstream
    SSO_PLUGIN_VERSION = var.jellyfin_sso_plugin_version
  }

  # The wget + unzip extractor stage runs in alpine — under 5min normally,
  # but 10m gives headroom on a cold registry.
  resources = {
    requests = { cpu = "200m", memory = "512Mi" }
    limits   = { cpu = "2", memory = "2Gi" }
  }
  timeout = "10m"

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}

locals {
  # Plain Python — env vars carry runtime config, no templatefile() needed.
  jellyfin_seed_script = file("${path.module}/../data/jellyfin/seed.py")

  # CSV of Jellyfin local users to ensure exist. Names use the FULL
  # Zitadel login_name form (`<user_name>@<magic_domain>`) because that
  # is what Zitadel's `preferred_username` claim emits, and the SSO
  # plugin's username-match path keys off `preferred_username`. Seeding
  # with the bare username would JIT-create a duplicate user on first
  # OIDC login.
  jellyfin_users_csv = join(",", [
    "${var.zitadel_personal_user.user_name}@${var.headscale_magic_domain}",
    "${var.zitadel_partner_user.user_name}@${var.headscale_magic_domain}",
  ])
  jellyfin_admin_users_csv = "${var.zitadel_personal_user.user_name}@${var.headscale_magic_domain}"
}

resource "kubernetes_config_map" "jellyfin_seed" {
  metadata {
    name      = "jellyfin-seed"
    namespace = kubernetes_namespace.jellyfin.metadata[0].name
  }
  data = {
    "seed.py" = local.jellyfin_seed_script
  }
}

# Re-runs whenever the seed script, the user list, the plugin version, or
# the Zitadel client_id changes. Job names are immutable once created, so
# any input flip forces a destroy-and-recreate (the only way to re-execute
# a completed Job).
resource "kubernetes_job" "jellyfin_seed" {
  metadata {
    name = "jellyfin-seed-${substr(sha1(join("|", [
      # Roll the (immutable) Job name when the runner image changes.
      var.python_base_image,
      local.jellyfin_seed_script,
      local.jellyfin_users_csv,
      local.jellyfin_admin_users_csv,
      var.jellyfin_sso_plugin_version,
      # Vault-mounted creds aren't visible to TF, but a Zitadel client-id
      # rotation always rolls the application resource; that flip is
      # enough to re-run the Job and re-POST plugin config.
      zitadel_application_oidc.jellyfin.client_id,
    ])), 0, 10)}"
    namespace = kubernetes_namespace.jellyfin.metadata[0].name
  }

  spec {
    backoff_limit = 5

    template {
      # Distinct label from the main Deployment so the jellyfin Service
      # selector (`app = jellyfin`) does NOT pick this Job pod up as an
      # endpoint. The jellyfin-to-oidc egress netpol uses a matchExpression
      # covering both `jellyfin` and `jellyfin-seed`.
      metadata {
        labels = { app = "jellyfin-seed" }
      }

      spec {
        service_account_name = kubernetes_service_account.jellyfin.metadata[0].name
        restart_policy       = "OnFailure"

        # Pin oidc.<magic> to Zitadel ClusterIP so any direct calls from
        # the Job (none today, but reserved for future tooling that
        # might hit Zitadel directly) bypass the Tailscale sidecar.
        host_aliases {
          ip        = data.terraform_remote_state.vault_conf.outputs.zitadel_cluster_ip
          hostnames = ["${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"]
        }

        # Wait for Vault CSI to land oidc_client_id before seed.py reads
        # it. Mirrors the audiobookshelf-jobs pattern.
        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "oidc_client_id"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        container {
          name              = "seed"
          image             = var.python_base_image
          image_pull_policy = "Always"

          command = ["uv", "run", "--no-project", "/etc/jellyfin-seed/seed.py"]

          env {
            name  = "JELLYFIN_URL"
            # Internal HTTP — bypasses TLS + nginx, faster + simpler.
            value = "http://jellyfin.${kubernetes_namespace.jellyfin.metadata[0].name}.svc.cluster.local:8096"
          }
          env {
            name  = "JELLYFIN_PUBLIC_URL"
            # Used to compose the SSO plugin's redirect URI. Must match
            # what's registered on the Zitadel client.
            value = "https://${var.jellyfin_domain}.${local.magic_fqdn_suffix}"
          }
          env {
            name  = "USERS"
            value = local.jellyfin_users_csv
          }
          env {
            name  = "ADMIN_USERS"
            value = local.jellyfin_admin_users_csv
          }
          env {
            name  = "SEED_USER"
            value = "_seed"
          }
          env {
            name  = "SECRETS_DIR"
            value = "/mnt/secrets"
          }
          # Seed-state cache lives in a subdir, NOT at /config root.
          # Newer Jellyfin's BaseApplicationPaths.MakeSanityCheckOrThrow
          # rejects any `.jellyfin-*` marker file at the data-dir root that
          # isn't `.jellyfin-data` — our previous `/jf-config/.jellyfin-seed-state.json`
          # tripped that check and crashed jellyfin on boot (incident 2026-05-09).
          # save_seed_state() does parent.mkdir(parents=True, exist_ok=True),
          # so the subdir is created on first run.
          env {
            name  = "SEED_STATE_PATH"
            value = "/jf-config/seed/state.json"
          }
          env {
            name  = "OIDC_PROVIDER"
            value = "zitadel"
          }
          env {
            name  = "OIDC_ISSUER_URL"
            value = "https://${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"
          }
          env {
            name  = "OIDC_BUTTON_TEXT"
            value = "Login with Zitadel"
          }
          env {
            name  = "PYTHONUNBUFFERED"
            value = "1"
          }

          volume_mount {
            name       = "seed"
            mount_path = "/etc/jellyfin-seed"
            read_only  = true
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
          # Shared with the main Jellyfin pod (RWO + single-node K3s lets
          # both pods mount it). The Job only writes seed/state.json under
          # this path (NOT at the root — newer Jellyfin's sanity check
          # rejects unknown `.jellyfin-*` markers at the data-dir root).
          volume_mount {
            name       = "jellyfin-config"
            mount_path = "/jf-config"
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }
        }

        volume {
          name = "seed"
          config_map {
            name         = kubernetes_config_map.jellyfin_seed.metadata[0].name
            default_mode = "0555"
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.jellyfin_tls_vault.spc_name
            }
          }
        }
        volume {
          name = "jellyfin-config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.jellyfin_config.metadata[0].name
          }
        }
      }
    }
  }

  # Plugin install + user creation + SSO config takes ~1-2 min on a
  # fresh apply; 10m headroom for slow Jellyfin first-boot indexing.
  timeouts {
    create = "10m"
    update = "10m"
  }

  depends_on = [
    kubernetes_deployment.jellyfin,
    kubernetes_service.jellyfin,
  ]
}
