resource "kubernetes_deployment" "navidrome" {
  metadata {
    name      = "navidrome"
    namespace = kubernetes_namespace.navidrome.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "navidrome" }
    }

    template {
      metadata {
        labels = { app = "navidrome" }
        annotations = {
          "nginx-config-hash"                   = sha1(kubernetes_config_map.navidrome_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "navidrome-secrets,navidrome-tls"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.navidrome.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "navidrome_password"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Navidrome image runs as uid 1000 by default; ensure both PVCs are
        # writable to that uid on first apply (idempotent on subsequent rolls).
        init_container {
          name  = "fix-permissions"
          image = var.image_busybox
          command = [
            "sh", "-c",
            "chown -R 1000:1000 /data /music"
          ]
          volume_mount {
            name       = "navidrome-data"
            mount_path = "/data"
          }
          volume_mount {
            name       = "navidrome-music"
            mount_path = "/music"
          }
        }

        # Navidrome
        container {
          name  = "navidrome"
          image = var.image_navidrome

          port {
            container_port = 4533
            name           = "http"
          }

          env {
            name  = "ND_DATAFOLDER"
            value = "/data"
          }
          env {
            name  = "ND_MUSICFOLDER"
            value = "/music"
          }
          env {
            name  = "ND_PORT"
            value = "4533"
          }
          env {
            name  = "ND_LOGLEVEL"
            value = "info"
          }
          # Vault is the source of truth for the admin password. Navidrome
          # re-applies this value to the `admin` row on every boot, so a
          # `terraform apply -replace=random_password.navidrome_password`
          # followed by a pod restart is the rotation flow. Manual password
          # changes via the web UI are reverted on next restart by design.
          env {
            name = "ND_DEVAUTOCREATEADMINPASSWORD"
            value_from {
              secret_key_ref {
                name = "navidrome-secrets"
                key  = "navidrome_password"
              }
            }
          }

          volume_mount {
            name       = "navidrome-data"
            mount_path = "/data"
          }
          volume_mount {
            name       = "navidrome-music"
            mount_path = "/music"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }

          liveness_probe {
            http_get {
              path = "/ping"
              port = 4533
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/ping"
              port = 4533
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        # Navidrome Volumes
        volume {
          name = "navidrome-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.navidrome_data.metadata[0].name
          }
        }
        volume {
          name = "navidrome-music"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.navidrome_music.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.navidrome_secret_provider.manifest.metadata.name
            }
          }
        }

        # Nginx
        container {
          name  = "navidrome-nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "navidrome-tls"
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
          name = "navidrome-tls"
          secret { secret_name = "navidrome-tls" }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.navidrome_nginx_config.metadata[0].name
          }
        }

        # Tailscale
        container {
          name  = "navidrome-tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "navidrome-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.navidrome_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.navidrome_domain
          }
          env {
            name  = "TS_EXTRA_ARGS"
            value = "--login-server=https://${data.terraform_remote_state.homelab.outputs.headscale_server_fqdn}"
          }
          env {
            name  = "TS_TAILSCALED_EXTRA_ARGS"
            value = "--port=41641"
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
    kubernetes_manifest.navidrome_secret_provider
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}
