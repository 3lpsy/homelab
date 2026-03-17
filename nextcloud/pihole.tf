
resource "kubernetes_config_map" "pihole_nginx_config" {
  metadata {
    name      = "pihole-nginx-config"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }
  data = {
    "nginx.conf" = <<-EOT
      events {
        worker_connections 1024;
      }
      http {
        upstream pihole {
          server localhost:80;
        }
        server {
          listen 443 ssl;
          server_name ${var.pihole_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain};

          ssl_certificate     /etc/nginx/certs/tls.crt;
          ssl_certificate_key /etc/nginx/certs/tls.key;
          ssl_protocols       TLSv1.2 TLSv1.3;
          ssl_ciphers         HIGH:!aNULL:!MD5;
          ssl_prefer_server_ciphers on;

          add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

          location / {
            proxy_pass http://pihole;
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
          }
        }
      }
    EOT
  }
}



resource "kubernetes_deployment" "pihole" {
  metadata {
    name      = "pihole"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "pihole" }
    }

    template {
      metadata {
        labels = { app = "pihole" }
      }

      spec {
        service_account_name = kubernetes_service_account.pihole.metadata[0].name


        init_container {
          name  = "wait-for-secrets"
          image = "busybox:latest"
          command = [
            "sh", "-c",
            <<-EOT
              echo 'Waiting for pihole secrets to sync from Vault...'
              TIMEOUT=300
              ELAPSED=0
              until [ -f /mnt/secrets/admin_password ]; do
                if [ $ELAPSED -ge $TIMEOUT ]; then
                  echo "Timeout waiting for secrets after $${TIMEOUT}s"
                  exit 1
                fi
                echo "Still waiting... ($${ELAPSED}s)"
                sleep 5
                ELAPSED=$((ELAPSED + 5))
              done
              echo 'Pihole secrets synced successfully!'
            EOT
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        container {
          name  = "pihole-tailscale"
          image = "tailscale/tailscale:latest"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "pihole-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.pihole_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.pihole_domain
          }
          env {
            name  = "TS_EXTRA_ARGS"
            value = "--login-server=https://${data.terraform_remote_state.homelab.outputs.headscale_server_fqdn}"
          }

          security_context {
            capabilities {
              add = ["NET_ADMIN", "NET_BIND_SERVICE", "NET_RAW", "SYS_NICE", "CHOWN"]
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

        container {
          name  = "pihole-nginx"
          image = "nginx:alpine"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "pihole-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }

          resources {
            requests = { cpu = "50m",  memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        container {
          name  = "pihole"
          image = "pihole/pihole:latest"

          env {
            name = "FTLCONF_webserver_api_password"
            value_from {
              secret_key_ref {
                name = "pihole-secrets"
                key  = "admin_password"
              }
            }
          }
          env {
            name  = "FTLCONF_dns_upstreams"
            value = "9.9.9.9;149.112.112.112"
          }
          env {
            name  = "FTLCONF_dns_listeningMode"
            value = "all"
          }
          env {
            name  = "TZ"
            value = "America/Chicago"  # or wherever you are
          }


          port {
            container_port = 80
            name           = "http"
          }
          port {
            container_port = 53
            protocol       = "UDP"
            name           = "dns-udp"
          }
          port {
            container_port = 53
            protocol       = "TCP"
            name           = "dns-tcp"
          }

          volume_mount {
            name       = "pihole-data"
            mount_path = "/etc/pihole"
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
              path = "/admin"
              port = 80
            }
            initial_delay_seconds = 60
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/admin"
              port = 80
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        volume {
          name = "pihole-tls"
          secret { secret_name = "pihole-tls" }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.pihole_nginx_config.metadata[0].name
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
          name = "pihole-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.pihole_data.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.pihole_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.pihole_secret_provider
  ]
}
