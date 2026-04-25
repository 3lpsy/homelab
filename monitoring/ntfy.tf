resource "kubernetes_deployment" "ntfy" {
  metadata {
    name      = "ntfy"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "ntfy" }
    }

    template {
      metadata {
        labels = { app = "ntfy" }
        annotations = {
          "nginx-config-hash"                   = sha1(kubernetes_config_map.ntfy_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "ntfy-tls"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.ntfy.metadata[0].name

        init_container {
          name  = "fix-permissions"
          image = var.image_busybox
          command = [
            "sh", "-c",
            "chown -R 1000:1000 /var/lib/ntfy && chown -R 1000:1000 /var/cache/ntfy"
          ]
          volume_mount {
            name       = "ntfy-data"
            mount_path = "/var/lib/ntfy"
          }
          volume_mount {
            name       = "ntfy-cache"
            mount_path = "/var/cache/ntfy"
          }
        }

        # Ntfy
        container {
          name  = "ntfy"
          image = var.image_ntfy

          args = ["serve"]

          port {
            container_port = 8080
            name           = "http"
          }

          volume_mount {
            name       = "ntfy-config"
            mount_path = "/etc/ntfy"
            read_only  = true
          }
          volume_mount {
            name       = "ntfy-data"
            mount_path = "/var/lib/ntfy"
          }
          volume_mount {
            name       = "ntfy-cache"
            mount_path = "/var/cache/ntfy"
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "250m", memory = "256Mi" }
          }

          liveness_probe {
            http_get {
              path = "/v1/health"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/v1/health"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        # Ntfy Volumes
        volume {
          name = "ntfy-config"
          config_map {
            name = kubernetes_config_map.ntfy_server_config.metadata[0].name
          }
        }
        volume {
          name = "ntfy-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.ntfy_data.metadata[0].name
          }
        }
        volume {
          name = "ntfy-cache"
          empty_dir {}
        }

        # Nginx
        container {
          name  = "nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "ntfy-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        # Nginx Volumes
        volume {
          name = "ntfy-tls"
          secret { secret_name = "ntfy-tls" }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.ntfy_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.ntfy_secret_provider.manifest.metadata.name
            }
          }
        }

        # Tailscale
        container {
          name  = "tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "ntfy-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.ntfy_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.ntfy_domain
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

          volume_mount {
            name       = "dev-net-tun"
            mount_path = "/dev/net/tun"
          }
          volume_mount {
            name       = "tailscale-state"
            mount_path = "/var/lib/tailscale"
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "192Mi" }
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
    kubernetes_manifest.ntfy_secret_provider
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}
