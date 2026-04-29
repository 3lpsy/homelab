# In-cluster build pipeline for the nextcloud custom image. Uses the shared
# templates/buildkit-job module — see services/builder-buildkitd-config.tf
# for buildkitd.toml mirror config + `local.buildkit_job_shared`.

module "nextcloud_build" {
  source = "./../templates/buildkit-job"

  name      = "nextcloud"
  image_ref = local.nextcloud_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/nextcloud/Dockerfile")
  }

  # Bigger image, longer pulls than the MCP Pythons.
  resources = {
    requests = { cpu = "300m", memory = "768Mi" }
    limits   = { cpu = "3", memory = "3Gi" }
  }
  timeout = "20m"

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}

resource "kubernetes_job" "nextcloud_configure_collabora" {
  metadata {
    name      = "configure-collabora-${formatdate("YYYYMMDDhhmmss", timestamp())}"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    backoff_limit = 5

    template {
      metadata {}

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name
        restart_policy       = "OnFailure"

        image_pull_secrets {
          name = kubernetes_secret.registry_pull_secret.metadata[0].name
        }

        container {
          name  = "configure"
          image = local.nextcloud_image

          command = [
            "sh",
            "-c",
            <<-EOT
              until php occ status 2>/dev/null; do
                echo "Waiting for Nextcloud to be ready..."
                sleep 10
              done

              php occ config:system:set default_language --value="en"
              php occ config:system:set default_locale --value="en_US"
              php occ config:system:set force_language --value="en"

              # Reduce log noise: 0=debug, 1=info, 2=warn, 3=error, 4=fatal.
              php occ config:system:set loglevel --value=2 --type=integer

              echo "Configuring Collabora Office app..."

              php occ app:install richdocuments || echo "Collabora already installed"
              php occ app:enable richdocuments

              php occ config:app:set richdocuments wopi_url --value="https://${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
              php occ config:app:set richdocuments public_wopi_url --value="https://${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"

              php occ config:system:set allow_local_remote_servers --value=true --type=boolean

              php occ config:system:set overwriteprotocol --value=https
              php occ config:system:set overwrite.cli.url --value="https://${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"

              php occ config:system:set trusted_domains 2 --value="${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"

              php occ config:app:set richdocuments wopi_allowlist --value="127.0.0.1,::1,localhost,${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain},${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain},10.43.0.0/16,10.42.0.0/16,100.64.0.0/10"
              php occ config:app:set richdocuments doc_format --value="ooxml"

              php occ config:app:delete richdocuments discovery || true
              php occ config:app:delete richdocuments discovery_parsed || true
              php occ richdocuments:activate-config

              echo "Collabora configuration completed:"
              php occ config:app:get richdocuments wopi_url
              php occ config:app:get richdocuments public_wopi_url
              php occ config:app:get richdocuments wopi_allowlist
              php occ config:system:get allow_local_remote_servers
              php occ config:system:get trusted_domains

            EOT
          ]

          env {
            name  = "POSTGRES_HOST"
            value = "postgres"
          }

          env {
            name  = "POSTGRES_DB"
            value = "nextcloud"
          }

          env {
            name  = "POSTGRES_USER"
            value = "nextcloud"
          }

          env {
            name  = "REDIS_HOST"
            value = "redis"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          volume_mount {
            name       = "nextcloud-data"
            mount_path = "/var/www/html"
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        volume {
          name = "nextcloud-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.nextcloud_data.metadata[0].name
          }
        }

        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.nextcloud_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment.nextcloud,
    kubernetes_deployment.collabora
  ]

  lifecycle {
    ignore_changes = [
      metadata[0].name
    ]
  }
}

resource "kubernetes_job" "nextcloud_configure_previews" {
  metadata {
    name      = "configure-previews-${formatdate("YYYYMMDDhhmmss", timestamp())}"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    backoff_limit = 5

    template {
      metadata {}

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name
        restart_policy       = "OnFailure"

        image_pull_secrets {
          name = kubernetes_secret.registry_pull_secret.metadata[0].name
        }

        container {
          name  = "configure"
          image = local.nextcloud_image

          command = [
            "sh",
            "-c",
            <<-EOT
              until php occ status 2>/dev/null; do
                echo "Waiting for Nextcloud to be ready..."
                sleep 10
              done

              echo "Configuring preview providers..."

              php occ config:system:set enabledPreviewProviders 0 --value="OC\Preview\PNG"
              php occ config:system:set enabledPreviewProviders 1 --value="OC\Preview\JPEG"
              php occ config:system:set enabledPreviewProviders 2 --value="OC\Preview\GIF"
              php occ config:system:set enabledPreviewProviders 3 --value="OC\Preview\BMP"
              php occ config:system:set enabledPreviewProviders 4 --value="OC\Preview\XBitmap"
              php occ config:system:set enabledPreviewProviders 5 --value="OC\Preview\MarkDown"
              php occ config:system:set enabledPreviewProviders 6 --value="OC\Preview\MP3"
              php occ config:system:set enabledPreviewProviders 7 --value="OC\Preview\TXT"
              php occ config:system:set enabledPreviewProviders 8 --value="OC\Preview\Movie"
              php occ config:system:set enabledPreviewProviders 9 --value="OC\Preview\MP4"
              php occ config:system:set enabledPreviewProviders 10 --value="OC\Preview\MOV"
              php occ config:system:set enabledPreviewProviders 11 --value="OC\Preview\HEIC"
              php occ config:app:set richdocuments preview_enabled --value=no

              php occ config:system:set enable_previews --value=true --type=boolean
              php occ config:system:set "preview_disabled_mime_types" 0 --value="application/pdf"

              echo "Preview providers configured:"
              php occ config:system:get enabledPreviewProviders
            EOT
          ]

          env {
            name  = "POSTGRES_HOST"
            value = "postgres"
          }

          env {
            name  = "POSTGRES_DB"
            value = "nextcloud"
          }

          env {
            name  = "POSTGRES_USER"
            value = "nextcloud"
          }

          env {
            name  = "REDIS_HOST"
            value = "redis"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          volume_mount {
            name       = "nextcloud-data"
            mount_path = "/var/www/html"
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        volume {
          name = "nextcloud-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.nextcloud_data.metadata[0].name
          }
        }

        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.nextcloud_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment.nextcloud,
    kubernetes_service.nextcloud_postgres,
    kubernetes_service.nextcloud_redis,
    kubernetes_manifest.nextcloud_secret_provider
  ]

  lifecycle {
    ignore_changes = [
      metadata[0].name
    ]
  }
}
