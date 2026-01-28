
# Nginx config
resource "kubernetes_config_map" "nginx_config" {
  metadata {
    name      = "nginx-config"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  data = {
    "nginx.conf" = <<-EOT
      events {
        worker_connections 1024;
      }
      http {
        access_log /var/log/nginx/access.log;
        error_log /var/log/nginx/error.log;

        upstream nextcloud {
          server localhost:80;
        }

        upstream harp {
          server appapi-harp:8780;
        }

        server {
          listen 443 ssl http2;
          server_name ${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain};

          # SSL configuration
          ssl_certificate /etc/nginx/certs/tls.crt;
          ssl_certificate_key /etc/nginx/certs/tls.key;
          ssl_protocols TLSv1.2 TLSv1.3;
          ssl_ciphers HIGH:!aNULL:!MD5;
          ssl_prefer_server_ciphers on;

          # Proxy
          set_real_ip_from 127.0.0.1;
          set_real_ip_from ::1;
          real_ip_header X-Forwarded-For;
          real_ip_recursive on;


          # File upload limits
          client_max_body_size 20G;
          client_body_buffer_size 400M;

          # Timeouts for large file operations
          proxy_connect_timeout 3600;
          proxy_send_timeout 3600;
          proxy_read_timeout 3600;
          send_timeout 3600;

          # Add headers for security
          add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
          add_header X-Content-Type-Options "nosniff" always;
          add_header X-Frame-Options "SAMEORIGIN" always;
          add_header X-XSS-Protection "1; mode=block" always;
          add_header Referrer-Policy "no-referrer" always;
          add_header X-Robots-Tag "noindex, nofollow" always;

          location /exapps/ {
              proxy_pass http://harp;
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_set_header X-Forwarded-Host $host;
              proxy_set_header X-Forwarded-Port $server_port;

              # WebSocket support for ExApps
              proxy_http_version 1.1;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection "upgrade";

              # Disable buffering for streaming
              proxy_buffering off;
              proxy_request_buffering off;
            }

          # Nextcloud CalDAV/CardDAV redirects
          location = /.well-known/carddav {
            return 301 https://$host/remote.php/dav;
          }

          location = /.well-known/caldav {
            return 301 https://$host/remote.php/dav;
          }

          location / {
            proxy_pass http://nextcloud;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-Forwarded-Host $host;
            proxy_set_header X-Forwarded-Port $server_port;

            # Essential for Nextcloud
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_max_temp_file_size 0;
          }

        }
      }
    EOT
  }
}


# PVC for Nextcloud data
resource "kubernetes_persistent_volume_claim" "nextcloud_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "nextcloud-data"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"

    resources {
      requests = {
        storage = "50Gi"
      }
    }
  }
  wait_until_bound = false
}



# Nextcloud Deployment
resource "kubernetes_deployment" "nextcloud" {
  metadata {
    name      = "nextcloud"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    replicas = 1

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
        host_aliases {
          ip = kubernetes_service.collabora_internal.spec[0].cluster_ip
          hostnames = [
            "${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          ]
        }
        # Tailscale sidecar
        container {
          name  = "tailscale"
          image = "tailscale/tailscale:latest"

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

        # Nginx reverse proxy for TLS termination
        container {
          name  = "nginx"
          image = "nginx:alpine"

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
              memory = "1Gi"  # Increased for large file handling
            }
          }
        }

        # Nextcloud container
        container {
          name  = "nextcloud"
          image = "nextcloud:latest"

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

          # Mount the CSI volume to trigger secret sync
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
              memory = "2Gi"
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

        volume {
          name = "nextcloud-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.nextcloud_data.metadata[0].name
          }
        }

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

        # Mount the CSI volume for secret sync
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
      name        = "https" # Changed from "http"
      port        = 443     # Changed from 80
      target_port = 443     # Point to nginx's HTTPS port
    }

    type = "ClusterIP"
  }
}
