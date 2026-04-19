resource "kubernetes_deployment" "thunderbolt" {
  metadata {
    name      = "thunderbolt"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "thunderbolt"
      }
    }

    template {
      metadata {
        labels = {
          app = "thunderbolt"
        }
        annotations = {
          # Rolls the pod whenever the frontend build Job's name changes
          # (i.e. whenever any input file or the git ref changes → new image)
          # so `:latest` is actually re-pulled.
          "build-job"         = local.thunderbolt_frontend_build_job_name
          # Rolls on outer TLS/proxy nginx config changes.
          "nginx-config-hash" = sha1(kubernetes_config_map.thunderbolt_nginx_config.data["nginx.conf"])
        }
      }

      spec {
        service_account_name = kubernetes_service_account.thunderbolt.metadata[0].name

        image_pull_secrets {
          name = kubernetes_secret.thunderbolt_registry_pull_secret.metadata[0].name
        }

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "thunderbolt_tls_crt"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Frontend SPA (nginx serving dist on :80)
        container {
          name  = "frontend"
          image = local.thunderbolt_frontend_image

          port {
            container_port = 80
            name           = "http"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }
        }

        # TLS-terminating nginx (path routing to backend / powersync / keycloak)
        container {
          name  = "nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "thunderbolt-tls"
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
              cpu    = "300m"
              memory = "256Mi"
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
            value = "thunderbolt-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.thunderbolt_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.thunderbolt_domain
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

        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.thunderbolt_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "thunderbolt-tls"
          secret {
            secret_name = "thunderbolt-tls"
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.thunderbolt_secret_provider.manifest.metadata.name
            }
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
      }
    }
  }

  depends_on = [
    kubernetes_manifest.thunderbolt_secret_provider,
    kubernetes_deployment.thunderbolt_backend,
    kubernetes_manifest.thunderbolt_frontend_build,
  ]
}

resource "kubernetes_service" "thunderbolt" {
  metadata {
    name      = "thunderbolt"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }
  spec {
    selector = {
      app = "thunderbolt"
    }
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
  }
}
