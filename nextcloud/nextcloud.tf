resource "kubernetes_deployment" "nextcloud" {
  metadata {
    name      = "nextcloud"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        app = "nextcloud"
      }
    }

    template {
      metadata {
        labels = {
          app = "nextcloud"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name
        image_pull_secrets {
          name = kubernetes_secret.registry_pull_secret.metadata[0].name
        }
        host_aliases {
          ip = kubernetes_service.collabora_internal.spec[0].cluster_ip
          hostnames = [
            "${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          ]
        }

        # Nextcloud
        container {
          name  = "nextcloud"
          image = local.nextcloud_image

          port {
            container_port = 80
          }

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
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = "nextcloud-secrets"
                key  = "postgres_password"
              }
            }
          }

          env {
            name  = "REDIS_HOST"
            value = "redis"
          }

          env {
            name = "REDIS_HOST_PASSWORD"
            value_from {
              secret_key_ref {
                name = "nextcloud-secrets"
                key  = "redis_password"
              }
            }
          }

          env {
            name  = "REDIS_HOST_PORT"
            value = "6379"
          }

          env {
            name  = "NEXTCLOUD_ADMIN_USER"
            value = var.nextcloud_admin_user
          }

          env {
            name = "NEXTCLOUD_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = "nextcloud-secrets"
                key  = "admin_password"
              }
            }
          }

          env {
            name  = "NEXTCLOUD_CSP_ALLOWED_DOMAINS"
            value = "${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }

          env {
            name  = "NEXTCLOUD_TRUSTED_DOMAINS"
            value = "${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }

          env {
            name  = "OVERWRITEPROTOCOL"
            value = "https"
          }

          env {
            name  = "OVERWRITEHOST"
            value = "${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }

          env {
            name  = "OVERWRITECLIURL"
            value = "https://${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }

          env {
            name  = "TRUSTED_PROXIES"
            value = "127.0.0.1 ::1 10.42.0.0/16 10.43.0.0/16"
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

          resources {
            requests = {
              cpu    = "500m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "2000m"
              memory = "4Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/status.php"
              port = 80
              http_header {
                name  = "Host"
                value = "${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
              }
            }
            initial_delay_seconds = 180
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }

          readiness_probe {
            http_get {
              path = "/status.php"
              port = 80
              http_header {
                name  = "Host"
                value = "${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
              }
            }
            initial_delay_seconds = 120
            period_seconds        = 10
            timeout_seconds       = 3
            failure_threshold     = 30
          }
        }

        # Nextcloud Volumes
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

        # Nginx
        container {
          name  = "nextcloud-nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "nextcloud-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }

          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "2Gi"
            }
          }
        }

        # Nginx Volumes
        volume {
          name = "nextcloud-tls"
          secret {
            secret_name = "nextcloud-tls"
          }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.nginx_config.metadata[0].name
          }
        }

        # Tailscale
        container {
          name  = "nextcloud-tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }

          env {
            name  = "TS_KUBE_SECRET"
            value = "tailscale-state"
          }

          env {
            name  = "TS_USERSPACE"
            value = "false"
          }

          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }

          env {
            name  = "TS_HOSTNAME"
            value = var.nextcloud_domain
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
    kubernetes_manifest.nextcloud_secret_provider,
    kubernetes_service.postgres,
    kubernetes_service.redis
  ]
}

resource "kubernetes_service" "nextcloud_internal" {
  metadata {
    name      = "nextcloud-internal"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    selector = {
      app = "nextcloud"
    }

    port {
      name        = "https"
      port        = 443
      target_port = 443
    }

    type = "ClusterIP"
  }
}
