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
      local.audiobookshelf_seed_script,
      local.audiobookshelf_opml_blob,
      join(",", var.audiobookshelf_users),
      local.audiobookshelf_auto_download_json,
      tostring(var.audiobookshelf_podcast_default_max_episodes),
      var.audiobookshelf_podcast_default_schedule,
      tostring(var.audiobookshelf_podcast_initial_lookback_days),
      tostring(var.audiobookshelf_podcast_fresh_import_window_seconds),
    ])), 0, 10)}"
    namespace = kubernetes_namespace.audiobookshelf.metadata[0].name
  }

  spec {
    backoff_limit = 5

    template {
      metadata {}

      spec {
        service_account_name = kubernetes_service_account.audiobookshelf.metadata[0].name
        restart_policy       = "OnFailure"

        container {
          name  = "seed"
          image = var.image_audiobookshelf_seed

          # Stdlib-only Python — no apk add / pip install needed.
          command = ["python3", "/etc/abs-seed/seed.py"]

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
