
# Job to configure AppAPI with HaRP daemon
resource "kubernetes_job" "configure_appapi_harp" {
  metadata {
    name      = "configure-appapi-harp-${formatdate("YYYYMMDDhhmmss", timestamp())}"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    backoff_limit = 5

    template {
      metadata {}

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name
        restart_policy       = "OnFailure"

        container {
          name  = "configure"
          image = "nextcloud:latest"

          command = [
            "sh",
            "-c",
            <<-EOT
                        # Wait for Nextcloud to be ready
                        until php occ status 2>/dev/null; do
                          echo "Waiting for Nextcloud to be ready..."
                          sleep 10
                        done

                        echo "Nextcloud is ready, waiting for HaRP service..."

                        # Wait for HaRP to be accessible (using curl)
                        until curl -s --max-time 5 http://appapi-harp:8780/ >/dev/null 2>&1; do
                          echo "Waiting for HaRP service on appapi-harp:8780..."
                          sleep 5
                        done
                        echo "HaRP is accessible, configuring AppAPI..."

                        # Install AppAPI if not already installed
                        php occ app:install app_api || echo "AppAPI already installed or failed"
                        php occ app:enable app_api || echo "AppAPI already enabled"

                        # Unregister existing daemons
                        php occ app_api:daemon:unregister harp_k8s 2>/dev/null || true
                        php occ app_api:daemon:unregister manual_install 2>/dev/null || true

                        # Read the shared key from the mounted CSI volume
                        HARP_KEY=$(cat /mnt/secrets/harp_shared_key)

                        # Register HaRP daemon using HTTPS through nginx

                        php occ app_api:daemon:register \
                          harp_k8s \
                          "HaRP (Kubernetes)" \
                          docker-install \
                          http \
                          "appapi-harp:8780" \
                          "https://${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}" \
                          --net=host \
                          --harp \
                          --harp_frp_address="appapi-harp:8782" \
                          --harp_shared_key="$HARP_KEY" \
                          --set-default

                        echo "AppAPI HaRP daemon registered"
                        php occ app_api:daemon:list

                        echo "Checking if default is set..."
                        php occ config:app:get app_api default_daemon_config

                        echo "Final config:"
                        php occ config:list app_api
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
    kubernetes_deployment.harp,
    kubernetes_service.harp,
    kubernetes_service.postgres,
    kubernetes_service.redis,
    kubernetes_manifest.nextcloud_secret_provider
  ]

  lifecycle {
    ignore_changes = [
      metadata[0].name
    ]
  }
}




# Job to configure Collabora Office
resource "kubernetes_job" "configure_nextcloud_and_collabora" {
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

        container {
          name  = "configure"
          image = "nextcloud:latest"

          command = [
            "sh",
            "-c",
            <<-EOT
              # Wait for Nextcloud to be ready
              until php occ status 2>/dev/null; do
                echo "Waiting for Nextcloud to be ready..."
                sleep 10
              done

              php occ config:system:set default_language --value="en"
              php occ config:system:set default_locale --value="en_US"
              php occ config:system:set force_language --value="en"

              echo "Configuring Collabora Office app..."

              # Install Collabora app
              php occ app:install richdocuments || echo "Collabora already installed"
              php occ app:enable richdocuments

              # Configure Collabora with HTTPS URLs
              php occ config:app:set richdocuments wopi_url --value="https://${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
              php occ config:app:set richdocuments public_wopi_url --value="https://${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"

              # Allow Nextcloud to connect to local/internal servers
              php occ config:system:set allow_local_remote_servers --value=true --type=boolean

              # Set system overrides for HTTPS
              php occ config:system:set overwriteprotocol --value=https
              php occ config:system:set overwrite.cli.url --value="https://${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"

              # Add Collabora domain to trusted domains
              php occ config:system:set trusted_domains 2 --value="${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"

              # Set WOPI allowlist with correct format
              php occ config:app:set richdocuments wopi_allowlist --value="127.0.0.1,::1,localhost,${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain},${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain},10.43.0.0/16,10.42.0.0/16"
              # Misc
              php occ config:app:set richdocuments doc_format --value="ooxml"

              # Clear discovery cache and reactivate
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
    kubernetes_deployment.collabora,
    kubernetes_job.configure_appapi_harp
  ]

  lifecycle {
    ignore_changes = [
      metadata[0].name
    ]
  }
}
