resource "kubernetes_deployment" "homeassist" {
  metadata {
    name      = "homeassist"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "homeassist" }
    }

    template {
      metadata {
        labels = { app = "homeassist" }
        annotations = {
          "config-hash"                         = sha1(kubernetes_config_map.homeassist_config.data["configuration.yaml"])
          "nginx-config-hash"                   = sha1(kubernetes_config_map.homeassist_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "homeassist-tls"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.homeassist.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "tls_crt"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Copies the seeded configuration.yaml onto the PVC the first time the
        # pod starts, then ensures the !include target files exist so HA's
        # config validator doesn't fail before the user has created any
        # automations/scripts/scenes. Idempotent: subsequent boots skip the
        # copy if /config/configuration.yaml already exists, so user edits
        # made via the HA UI are preserved.
        init_container {
          name  = "seed-config"
          image = var.image_busybox
          command = [
            "sh", "-c",
            <<-EOT
              if [ ! -f /config/configuration.yaml ]; then
                cp /etc/configuration-seed/configuration.yaml /config/configuration.yaml
              fi
              touch /config/automations.yaml /config/scripts.yaml /config/scenes.yaml
            EOT
          ]
          volume_mount {
            name       = "homeassist-data"
            mount_path = "/config"
          }
          volume_mount {
            name       = "homeassist-config-seed"
            mount_path = "/etc/configuration-seed"
            read_only  = true
          }
        }

        # Skips the HA web onboarding wizard end-to-end:
        #  1. Pre-creates the admin via `hass --script auth add`. Idempotent:
        #     if the user already exists (manual onboarding or earlier apply),
        #     the init leaves the password alone so a UI-changed password is
        #     never silently reverted to the Vault value. Read the initial
        #     password with `vault kv get -field=admin_password secret/homeassist/config`.
        #  2. Pre-writes /config/.storage/onboarding marking all four wizard
        #     steps (user, core_config, analytics, integration) done so HA
        #     routes to the login page instead of /onboarding.html. Storage
        #     format matches homeassistant.components.onboarding STORAGE_VERSION
        #     = 4. Idempotent: only writes if the file is missing, so a
        #     partially-completed manual wizard isn't clobbered.
        init_container {
          name  = "seed-admin-user"
          image = var.image_homeassist
          command = [
            "sh", "-c",
            <<-EOT
              set -e
              USERNAME="${var.homeassist_admin_user}"
              PASSWORD=$(cat /mnt/secrets/admin_password)
              if [ -z "$PASSWORD" ]; then
                echo "ERROR: admin_password secret is empty" >&2
                exit 1
              fi
              EXISTING=$(hass --script auth -c /config list 2>/dev/null || true)
              if echo "$EXISTING" | grep -qE "^$USERNAME$"; then
                echo "User $USERNAME already exists, leaving password alone"
              else
                echo "Creating user $USERNAME..."
                hass --script auth -c /config add "$USERNAME" "$PASSWORD"
              fi
              # Always overwrite: HA may have written a partial-done file
              # mid-cancelled-wizard on a prior pod run. The data shape here
              # is "all four steps done" regardless of prior state, and the
              # actual user-configurable settings (timezone, location, etc.)
              # live in *other* .storage files that we don't touch.
              mkdir -p /config/.storage
              printf '%s' '{"version":4,"minor_version":1,"key":"onboarding","data":{"done":["user","core_config","analytics","integration"]}}' > /config/.storage/onboarding
              echo "Marked onboarding wizard complete"

              # Seed core.config with Austin/Central/US defaults so HA isn't
              # left at UTC + EUR + no country (which trips the "country not
              # configured" repair issue and breaks integrations that key off
              # locale). Storage layout matches homeassistant.core_config
              # CORE_STORAGE_VERSION=1 / MINOR_VERSION=4. Idempotent: only
              # writes when the file is missing or country is still null
              # (HA's unset sentinel), so a UI-set country/location/lat-long
              # is never reverted on later pod restarts.
              if [ ! -f /config/.storage/core.config ] || grep -q '"country": *null' /config/.storage/core.config 2>/dev/null; then
                printf '%s' '{"version":1,"minor_version":4,"key":"core.config","data":{"latitude":30.2672,"longitude":-97.7431,"elevation":149,"radius":100,"unit_system_v2":"us_customary","location_name":"Home","time_zone":"${var.homeassist_time_zone}","external_url":null,"internal_url":"https://${var.homeassist_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}","currency":"USD","country":"US","language":"en"}}' > /config/.storage/core.config
                echo "Seeded core.config with US/Austin/Central defaults"
              else
                echo "core.config already configured, leaving alone"
              fi
            EOT
          ]
          volume_mount {
            name       = "homeassist-data"
            mount_path = "/config"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Home Assistant
        container {
          name  = "homeassistant"
          image = var.image_homeassist

          port {
            container_port = 8123
            name           = "http"
          }

          env {
            name  = "TZ"
            value = var.homeassist_time_zone
          }

          volume_mount {
            name       = "homeassist-data"
            mount_path = "/config"
          }
          # Pins the CSI secrets-store volume so the synced `homeassist-tls`
          # k8s secret stays alive for the nginx sidecar; HA itself never
          # reads from this path.
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "500m", memory = "512Mi" }
            limits   = { cpu = "2000m", memory = "2Gi" }
          }

          liveness_probe {
            tcp_socket {
              port = 8123
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            timeout_seconds       = 10
            failure_threshold     = 5
          }

          readiness_probe {
            tcp_socket {
              port = 8123
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        # Home Assistant Volumes
        volume {
          name = "homeassist-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.homeassist_config.metadata[0].name
          }
        }
        volume {
          name = "homeassist-config-seed"
          config_map {
            name = kubernetes_config_map.homeassist_config.metadata[0].name
          }
        }

        # Nginx
        container {
          name  = "homeassist-nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "homeassist-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        # Nginx Volumes
        volume {
          name = "homeassist-tls"
          secret { secret_name = "homeassist-tls" }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.homeassist_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.homeassist_secret_provider.manifest.metadata.name
            }
          }
        }

        # Tailscale
        container {
          name  = "homeassist-tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "homeassist-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.homeassist_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.homeassist_domain
          }
          env {
            name  = "TS_EXTRA_ARGS"
            value = "--login-server=https://${data.terraform_remote_state.homelab.outputs.headscale_server_fqdn}"
          }

          security_context {
            capabilities {
              add = ["NET_ADMIN"]
            }
          }

          resources {
            requests = {
              cpu    = "20m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }

          volume_mount {
            name       = "dev-net-tun"
            mount_path = "/dev/net/tun"
          }
          volume_mount {
            name       = "tailscale-state"
            mount_path = "/var/lib/tailscale"
          }
        }

        # Tailscale Volumes
        volume {
          name = "dev-net-tun"
          host_path {
            path = "/dev/net/tun"
            type = "CharDevice"
          }
        }
        volume {
          name = "tailscale-state"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.homeassist_secret_provider
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}
