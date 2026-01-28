
# Nginx config for Collabora
resource "kubernetes_config_map" "collabora_nginx_config" {
  metadata {
    name      = "collabora-nginx-config"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  data = {
    "nginx.conf" = <<-EOT
      events {
        worker_connections 1024;
      }
      http {
        upstream collabora {
          server localhost:9980;
        }

        map $http_upgrade $connection_upgrade {
          default upgrade;
          '' close;
        }

        server {
          # Do not use http2 for now as it may cause issues
          listen 443 ssl;
          server_name ${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain};

          # SSL configuration
          ssl_certificate /etc/nginx/certs/tls.crt;
          ssl_certificate_key /etc/nginx/certs/tls.key;
          ssl_protocols TLSv1.2 TLSv1.3;
          ssl_ciphers HIGH:!aNULL:!MD5;
          ssl_prefer_server_ciphers on;

          # Security headers
          add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

          # Collabora-specific settings
          client_max_body_size 0;
          proxy_read_timeout 36000s;

          # static files
          location ^~ /browser {
            proxy_pass http://collabora;
            proxy_set_header Host $http_host;
          }

          # WOPI discovery URL
          location ^~ /hosting/discovery {
            proxy_pass http://collabora;
            proxy_set_header Host $http_host;
          }

          # Capabilities
          location ^~ /hosting/capabilities {
            proxy_pass http://collabora;
            proxy_set_header Host $http_host;
          }

          # Admin Console websocket (most specific first)
             location ^~ /cool/adminws {
               proxy_pass http://collabora;
               proxy_set_header Upgrade $http_upgrade;
               proxy_set_header Connection $connection_upgrade;
               proxy_set_header Host $http_host;
               proxy_set_header X-Forwarded-Host $host;
               proxy_set_header X-Forwarded-Proto $scheme;
               proxy_read_timeout 36000s;
               proxy_http_version 1.1;
             }

             # CRITICAL: ALL /cool/ paths go to Collabora with WebSocket support
             # Collabora handles WebSocket upgrade internally
             location /cool/ {
               proxy_pass http://collabora;
               proxy_set_header Upgrade $http_upgrade;
               proxy_set_header Connection $connection_upgrade;
               proxy_set_header Host $http_host;
               proxy_set_header X-Forwarded-Host $host;
               proxy_set_header X-Forwarded-Proto $scheme;
               proxy_read_timeout 36000s;
               proxy_http_version 1.1;

               # Disable buffering for WebSocket
               proxy_buffering off;
               proxy_request_buffering off;
             }

        }
      }
    EOT
  }
}

# Collabora Deployment
resource "kubernetes_deployment" "collabora" {
  metadata {
    name      = "collabora"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "collabora"
      }
    }

    template {
      metadata {
        labels = {
          app = "collabora"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name
        host_aliases {
          ip = kubernetes_service.nextcloud_internal.spec[0].cluster_ip
          hostnames = [
            "${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          ]
        }
        init_container {
          name  = "wait-for-secrets"
          image = "busybox:latest"

          command = [
            "sh",
            "-c",
            <<-EOT
                    echo 'Waiting for Collabora secrets to sync from Vault...'
                    TIMEOUT=300
                    ELAPSED=0
                    until [ -f /mnt/secrets/collabora_password ]; do
                      if [ $ELAPSED -ge $TIMEOUT ]; then
                        echo "Timeout waiting for secrets after $${TIMEOUT}s"
                        exit 1
                      fi
                      echo "Still waiting... ($${ELAPSED}s)"
                      sleep 5
                      ELAPSED=$((ELAPSED + 5))
                    done
                    echo 'Collabora secrets synced successfully!'
                    ls -la /mnt/secrets/
                  EOT
          ]

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
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
            value = "collabora-tailscale-state"
          }

          env {
            name  = "TS_USERSPACE"
            value = "false"
          }

          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.collabora_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }

          env {
            name  = "TS_HOSTNAME"
            value = var.collabora_domain
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
            name       = "collabora-tls"
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
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }
        }

        # Collabora container
        container {
          name  = "collabora"
          image = "collabora/code:latest"

          env {
            name  = "aliasgroup1"
            value = "https://${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }

          env {
            name  = "server_name"
            value = "${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }



          env {
            name  = "username"
            value = "admin"
          }

          env {
            name = "password"
            value_from {
              secret_key_ref {
                name = "nextcloud-secrets"
                key  = "collabora_password"
              }
            }
          }
          env {
            name = "extra_params"
            # Use .* to allow all hosts temporarily
            value = "--o:ssl.enable=false --o:ssl.termination=true --o:net.proto=https --o:storage.wopi.host=${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain} --o:logging.level=warning --o:language=en-US"
          }
          env {
            name  = "dictionaries"
            value = "en_US"
          }
          env {
            name  = "LC_CTYPE"
            value = "en_US.UTF-8"
          }

          env {
            name  = "LC_ALL"
            value = "en_US.UTF-8"
          }

          port {
            container_port = 9980
            name           = "http"
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "500m"
              memory = "1Gi"
            }
            limits = {
              cpu    = "2000m"
              memory = "4Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/hosting/discovery"
              port = 9980
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            timeout_seconds       = 10
          }

          readiness_probe {
            http_get {
              path = "/hosting/discovery"
              port = 9980
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        volume {
          name = "collabora-tls"
          secret {
            secret_name = "collabora-tls"
          }
        }

        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.collabora_nginx_config.metadata[0].name
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
    kubernetes_manifest.nextcloud_secret_provider
  ]
}

# Collabora Service (internal only - accessed via Tailscale)
# Internal service for Nextcloud -> Collabora communication
resource "kubernetes_service" "collabora_internal" {
  metadata {
    name      = "collabora-internal"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    selector = {
      app = "collabora"
    }

    port {
      name        = "https" # Changed from "http"
      port        = 443     # Changed from 9980
      target_port = 443     # Point to nginx's HTTPS port
    }

    type = "ClusterIP"
  }
}
