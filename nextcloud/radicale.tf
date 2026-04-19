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
        annotations = {
          "config-hash"       = sha1("${kubernetes_config_map.radicale_config.data["config"]}|${kubernetes_config_map.radicale_config.data["rights"]}")
          "nginx-config-hash" = sha1(kubernetes_config_map.radicale_nginx_config.data["nginx.conf"])
        }
      }

      spec {
        service_account_name = kubernetes_service_account.radicale.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "radicale_password"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        init_container {
          name  = "setup-auth"
          image = var.image_python
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
            name = "RADICALE_PASS"
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

        init_container {
          name  = "fix-permissions"
          image = var.image_busybox
          command = [
            "sh", "-c",
            "chown -R 1000:1000 /var/lib/radicale/collections"
          ]
          volume_mount {
            name       = "radicale-data"
            mount_path = "/var/lib/radicale/collections"
          }
        }

        # Radicale
        container {
          name  = "radicale"
          image = var.image_radicale

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

        # Radicale Volumes
        volume {
          name = "radicale-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.radicale_data.metadata[0].name
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
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.radicale_secret_provider.manifest.metadata.name
            }
          }
        }

        # Nginx
        container {
          name  = "radicale-nginx"
          image = var.image_nginx

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

        # Nginx Volumes
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
          name = "nginx-auth"
          empty_dir {}
        }

        # Tailscale
        container {
          name  = "radicale-tailscale"
          image = var.image_tailscale

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
    kubernetes_manifest.radicale_secret_provider
  ]
}
