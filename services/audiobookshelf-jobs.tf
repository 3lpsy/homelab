# OPML preseed: prefer the user's gitignored `podcasts.opml`; if missing,
# fall back to the checked-in `podcasts.example.opml` so a clean clone
# applies with a sensible default subscription. If neither exists the seed
# Job sees an empty OPML and skips the import step.
locals {
  audiobookshelf_opml_user    = "${path.module}/../${var.audiobookshelf_opml_path}"
  audiobookshelf_opml_example = "${path.module}/../data/audiobookshelf/podcasts.example.opml"
  audiobookshelf_opml_blob = fileexists(local.audiobookshelf_opml_user) ? file(local.audiobookshelf_opml_user) : (
    fileexists(local.audiobookshelf_opml_example) ? file(local.audiobookshelf_opml_example) : ""
  )

  # Seed script is plain Python, not templated — env vars carry runtime config.
  audiobookshelf_seed_script = file("${path.module}/../data/audiobookshelf/seed.py")

  audiobookshelf_auto_download_json = jsonencode(var.audiobookshelf_auto_download_podcasts)
}

resource "kubernetes_config_map" "audiobookshelf_seed" {
  metadata {
    name      = "audiobookshelf-seed"
    namespace = kubernetes_namespace.audiobookshelf.metadata[0].name
  }
  data = {
    "seed.py"       = local.audiobookshelf_seed_script
    "podcasts.opml" = local.audiobookshelf_opml_blob
  }
}

# Bootstrap + reconcile Job. Re-runs whenever the seed script, the OPML, or
# the user list changes — name is hashed off all three so any drift forces
# a destroy-and-recreate (which is the only way to re-run a completed Job).
resource "kubernetes_job" "audiobookshelf_seed" {
  metadata {
    name = "audiobookshelf-seed-${substr(sha1(join("|", [
      # Roll the (immutable) Job name when the runner image changes.
      var.python_base_image,
      local.audiobookshelf_seed_script,
      local.audiobookshelf_opml_blob,
      join(",", var.audiobookshelf_users),
      local.audiobookshelf_auto_download_json,
      tostring(var.audiobookshelf_podcast_default_max_episodes),
      var.audiobookshelf_podcast_default_schedule,
      tostring(var.audiobookshelf_podcast_initial_lookback_days),
      tostring(var.audiobookshelf_podcast_fresh_import_window_seconds),
      var.audiobookshelf_podcast_mark_finished_percent == null ? "" : tostring(var.audiobookshelf_podcast_mark_finished_percent),
      # OIDC inputs — Vault-mounted creds aren't visible to TF, but a
      # Zitadel client-id rotation always rolls the application resource,
      # which is enough to force the Job to re-run.
      zitadel_application_oidc.audiobookshelf.client_id,
      var.zitadel_personal_user.email,
    ])), 0, 10)}"
    namespace = kubernetes_namespace.audiobookshelf.metadata[0].name
  }

  spec {
    backoff_limit = 5

    template {
      # Distinct label from the main Deployment so the audiobookshelf
      # Service selector (`app = audiobookshelf`) does NOT pick this Job
      # pod up as an endpoint — when it did, kube-proxy round-robined to
      # the seed pod (no :80 listener) and seed PATCHes hit ECONNREFUSED.
      # The audiobookshelf_to_oidc egress NetworkPolicy uses a matchExpression
      # that covers both `audiobookshelf` and `audiobookshelf-seed`.
      metadata {
        labels = { app = "audiobookshelf-seed" }
      }

      spec {
        service_account_name = kubernetes_service_account.audiobookshelf.metadata[0].name
        restart_policy       = "OnFailure"

        # Pin oidc.<tailnet> to the Zitadel ClusterIP so any outbound calls
        # from the Job (none today, but reserved for future tooling that
        # might hit the issuer directly) bypass the Tailscale sidecar.
        # ABS itself does the heavy lifting — this is just defence-in-depth.
        host_aliases {
          ip        = data.terraform_remote_state.vault_conf.outputs.zitadel_cluster_ip
          hostnames = ["${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"]
        }

        # Wait for Vault CSI to land oidc_client_id before seed.py reads it.
        # Mirrors the deployment's wait-for-secrets pattern.
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
          name  = "seed"
          image = var.python_base_image
          image_pull_policy = "Always"

          # Stdlib-only Python — uv run on the shared python-base image.
          command = ["uv", "run", "--no-project", "/etc/abs-seed/seed.py"]

          env {
            name  = "ABS_URL"
            value = "http://audiobookshelf.${kubernetes_namespace.audiobookshelf.metadata[0].name}.svc.cluster.local"
          }
          env {
            name  = "USERS"
            value = join(",", var.audiobookshelf_users)
          }
          env {
            name  = "ROOT_USER"
            value = var.audiobookshelf_users[0]
          }
          env {
            name  = "SECRETS_DIR"
            value = "/mnt/secrets"
          }
          env {
            name  = "OPML_PATH"
            value = "/etc/abs-seed/podcasts.opml"
          }
          env {
            name  = "PODCASTS_DIR"
            value = "/podcasts"
          }
          env {
            name  = "PYTHONUNBUFFERED"
            value = "1"
          }
          env {
            name  = "PODCAST_DEFAULT_MAX_EPISODES"
            value = tostring(var.audiobookshelf_podcast_default_max_episodes)
          }
          env {
            name  = "PODCAST_DEFAULT_SCHEDULE"
            value = var.audiobookshelf_podcast_default_schedule
          }
          env {
            name  = "AUTO_DOWNLOAD_PODCASTS"
            value = local.audiobookshelf_auto_download_json
          }
          env {
            name  = "PODCAST_INITIAL_LOOKBACK_DAYS"
            value = tostring(var.audiobookshelf_podcast_initial_lookback_days)
          }
          env {
            name  = "PODCAST_FRESH_IMPORT_WINDOW_SECONDS"
            value = tostring(var.audiobookshelf_podcast_fresh_import_window_seconds)
          }
          env {
            # Empty string disables the library-level mark-finished PATCH;
            # the seed script treats unset / blank as "leave ABS default".
            name  = "PODCAST_MARK_FINISHED_PERCENT"
            value = var.audiobookshelf_podcast_mark_finished_percent == null ? "" : tostring(var.audiobookshelf_podcast_mark_finished_percent)
          }

          # OIDC reconcile inputs. Empty OIDC_ISSUER_URL would make seed.py's
          # reconcile_oidc step a no-op — kept non-empty here because the
          # Zitadel resources are always present.
          env {
            name  = "OIDC_ISSUER_URL"
            value = "https://${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"
          }
          env {
            name  = "OIDC_MATCH_EMAIL"
            value = var.zitadel_personal_user.email
          }
          env {
            name  = "OIDC_BUTTON_TEXT"
            value = "Login with Zitadel"
          }

          # Per-section hash cache. Lives on the same PVC ABS uses for its
          # SQLite DB, so a PVC wipe (full rebuild) automatically invalidates
          # the cache and forces a clean re-seed.
          env {
            name  = "SEED_STATE_PATH"
            value = "/abs-config/.seed-state.json"
          }

          volume_mount {
            name       = "seed"
            mount_path = "/etc/abs-seed"
            read_only  = true
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
          # Shared with the ABS pod (RWO + single-node K3s lets both pods
          # mount it). The Job only writes /.seed-state.json under this dir.
          volume_mount {
            name       = "audiobookshelf-config"
            mount_path = "/abs-config"
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }
        }

        volume {
          name = "seed"
          config_map {
            name         = kubernetes_config_map.audiobookshelf_seed.metadata[0].name
            default_mode = "0555"
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.audiobookshelf_tls_vault.spc_name
            }
          }
        }
        volume {
          name = "audiobookshelf-config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.audiobookshelf_config.metadata[0].name
          }
        }
      }
    }
  }

  # Seed Job's checknew step does a real RSS fetch per freshly-imported
  # podcast — easily 5–15 minutes on a fresh OPML. Default TF wait is ~1m
  # which fails out before the Job completes. 30m gives plenty of headroom
  # for ~130 RSS fetches plus the up-to-5min settings_wait_seconds poll.
  timeouts {
    create = "30m"
    update = "30m"
  }

  depends_on = [
    kubernetes_deployment.audiobookshelf,
    kubernetes_service.audiobookshelf,
  ]
}
