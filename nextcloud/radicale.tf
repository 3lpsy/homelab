resource "kubernetes_config_map" "radicale_config" {
  metadata {
    name      = "radicale-config"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }
  data = {
    "config" = <<-EOT
      [server]
      hosts = 0.0.0.0:5232
      max_connections = 5
      max_content_length = 100000000
      timeout = 30

      [auth]
      type = http_x_remote_user
      htpasswd_filename = /etc/radicale/users
      htpasswd_encryption = md5
      delay = 1

      [storage]
      filesystem_folder = /var/lib/radicale/collections

      [rights]
      type = from_file
      file = /etc/radicale/rights

      [logging]
      level = warning

      [web]
      type = none
    EOT

    "rights" = <<-EOT
      [root]
      user: .+
      collection:
      permissions: R

      [principal]
      user: .+
      collection: {user}
      permissions: RW

      [calendars]
      user: .+
      collection: {user}/[^/]+
      permissions: rw
    EOT
  }
}

resource "kubernetes_config_map" "radicale_nginx_config" {
  metadata {
    name      = "radicale-nginx-config"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }
  data = {
    "nginx.conf" = <<-EOT
      events {
        worker_connections 1024;
      }
      http {
        upstream radicale {
          server localhost:5232;
        }
        server {
          listen 443 ssl;
          server_name ${var.radicale_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain};

          ssl_certificate     /etc/nginx/certs/tls.crt;
          ssl_certificate_key /etc/nginx/certs/tls.key;
          ssl_protocols       TLSv1.2 TLSv1.3;
          ssl_ciphers         HIGH:!aNULL:!MD5;
          ssl_prefer_server_ciphers on;

          add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

          location /radicale/ {
            proxy_pass        http://radicale/;
            proxy_set_header  X-Script-Name /radicale;
            proxy_set_header  X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header  X-Forwarded-Proto $scheme;
            proxy_set_header  X-Remote-User $remote_user;
            proxy_set_header  Host $http_host;
            auth_basic           "Radicale - Password Required";
            auth_basic_user_file /etc/nginx/htpasswd;
          }

          location = / {
            return 301 /radicale/;
          }

          location = /.well-known/carddav {
            return 301 /radicale/;
          }
          location = /.well-known/caldav {
            return 301 /radicale/;
          }
        }
      }
    EOT
  }
}

resource "kubernetes_deployment" "radicale" {
  metadata {
    name      = "radicale"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "radicale" }
    }

    template {
      metadata {
        labels = { app = "radicale" }
      }

      spec {
        service_account_name = kubernetes_service_account.radicale.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = "busybox:latest"
          command = [
            "sh", "-c",
            <<-EOT
              echo 'Waiting for radicale secrets to sync from Vault...'
              TIMEOUT=300
              ELAPSED=0
              until [ -f /mnt/secrets/radicale_password ]; do
                if [ $ELAPSED -ge $TIMEOUT ]; then
                  echo "Timeout waiting for secrets after $${TIMEOUT}s"
                  exit 1
                fi
                echo "Still waiting... ($${ELAPSED}s)"
                sleep 5
                ELAPSED=$((ELAPSED + 5))
              done
              echo 'Radicale secrets synced successfully!'
            EOT
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Generate htpasswd from vault password for both nginx and radicale
        init_container {
                  name  = "setup-auth"
                  image = "python:3-alpine"
                  command = [
                    "sh", "-c",
                    <<-EOT
                      pip install --quiet passlib[bcrypt]
                      python -c "
                      import os
                      from passlib.hash import apr_md5_crypt
                      p = os.environ['RADICALE_PASS']
                      print('jim:' + apr_md5_crypt.hash(p))
                      " > /etc/radicale/users
                      chmod 640 /etc/radicale/users
                      chown 1000:1000 /etc/radicale/users
                      cp /etc/radicale/users /etc/nginx-auth/htpasswd
                      chmod 644 /etc/nginx-auth/htpasswd
                    EOT
                  ]

           env {
             name  = "RADICALE_PASS"
             value_from {
               secret_key_ref {
                 name = "radicale-secrets"
                 key  = "radicale_password"
               }
             }
           }

           volume_mount {
             name       = "secrets-store"
             mount_path = "/mnt/secrets"
             read_only  = true
           }
           volume_mount {
             name       = "radicale-auth"
             mount_path = "/etc/radicale"
           }
           volume_mount {
             name       = "nginx-auth"
             mount_path = "/etc/nginx-auth"
           }
         }

        # Fix ownership on data dir for radicale user (UID 1000 in image)
        init_container {
          name  = "fix-permissions"
          image = "busybox:latest"
          command = [
            "sh", "-c",
            "chown -R 1000:1000 /var/lib/radicale/collections"
          ]
          volume_mount {
            name       = "radicale-data"
            mount_path = "/var/lib/radicale/collections"
          }
        }

        container {
          name  = "radicale-tailscale"
          image = "tailscale/tailscale:latest"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "radicale-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.radicale_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.radicale_domain
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

        container {
          name  = "radicale-nginx"
          image = "nginx:alpine"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "radicale-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }
          volume_mount {
            name       = "nginx-auth"
            mount_path = "/etc/nginx/htpasswd"
            sub_path   = "htpasswd"
            read_only  = true
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        container {
          name  = "radicale"
          image = "ghcr.io/kozea/radicale:latest"

          args = ["--config", "/etc/radicale/config"]

          port {
            container_port = 5232
            name           = "http"
          }

          volume_mount {
            name       = "radicale-data"
            mount_path = "/var/lib/radicale/collections"
          }
          volume_mount {
            name       = "radicale-config-vol"
            mount_path = "/etc/radicale/config"
            sub_path   = "config"
          }
          volume_mount {
            name       = "radicale-config-vol"
            mount_path = "/etc/radicale/rights"
            sub_path   = "rights"
          }
          volume_mount {
            name       = "radicale-auth"
            mount_path = "/etc/radicale/users"
            sub_path   = "users"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "250m", memory = "256Mi" }
          }

          liveness_probe {
            tcp_socket {
              port = 5232
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            tcp_socket {
              port = 5232
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        volume {
          name = "radicale-tls"
          secret { secret_name = "radicale-tls" }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.radicale_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "radicale-config-vol"
          config_map {
            name = kubernetes_config_map.radicale_config.metadata[0].name
          }
        }
        volume {
          name = "radicale-auth"
          empty_dir {}
        }
        volume {
          name = "nginx-auth"
          empty_dir {}
        }
        volume {
          name = "radicale-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.radicale_data.metadata[0].name
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
              secretProviderClass = kubernetes_manifest.radicale_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.radicale_secret_provider
  ]
}
