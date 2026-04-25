resource "kubernetes_deployment" "searxng" {
  metadata {
    name      = "searxng"
    namespace = kubernetes_namespace.searxng.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "searxng"
      }
    }

    template {
      metadata {
        labels = {
          app = "searxng"
        }
        annotations = {
          "nginx-config-hash"                      = sha1(kubernetes_config_map.searxng_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload"    = "searxng-secrets,searxng-tls"
          # Reloader watches searxng-config and rolls this Deployment whenever
          # the ranker daemon rewrites it.
          "configmap.reloader.stakater.com/reload" = "searxng-config"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.searxng.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "searxng_tls_crt"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Copy settings.yml into a writable volume so the searxng entrypoint
        # can sed-substitute the `ultrasecretkey` placeholder with SEARXNG_SECRET.
        init_container {
          name  = "copy-config"
          image = var.image_busybox
          command = [
            "sh", "-c",
            "cp /config-ro/settings.yml /etc/searxng/settings.yml && chown -R 977:977 /etc/searxng && chmod 664 /etc/searxng/settings.yml"
          ]
          volume_mount {
            name       = "searxng-config-ro"
            mount_path = "/config-ro"
            read_only  = true
          }
          volume_mount {
            name       = "searxng-etc"
            mount_path = "/etc/searxng"
          }
        }

        # SearXNG
        container {
          name              = "searxng"
          image             = var.image_searxng
          image_pull_policy = "Always"

          env {
            name = "SEARXNG_SECRET"
            value_from {
              secret_key_ref {
                name = "searxng-secrets"
                key  = "secret_key"
              }
            }
          }
          env {
            name  = "SEARXNG_BASE_URL"
            value = "https://${local.searxng_fqdn}/"
          }
          env {
            name  = "SEARXNG_BIND_ADDRESS"
            value = "0.0.0.0"
          }
          env {
            name  = "SEARXNG_PORT"
            value = "8080"
          }
          env {
            name  = "UWSGI_WORKERS"
            value = "4"
          }
          env {
            name  = "UWSGI_THREADS"
            value = "4"
          }

          port {
            container_port = 8080
            name           = "http"
          }

          volume_mount {
            name       = "searxng-etc"
            mount_path = "/etc/searxng"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }
        }

        # Valkey cache — localhost sidecar for searxng request cache
        # and limiter state. Ephemeral emptyDir; fine to lose on restart.
        container {
          name  = "valkey"
          image = var.image_valkey

          args = [
            "--save", "",
            "--appendonly", "no",
            "--maxmemory", "128mb",
            "--maxmemory-policy", "allkeys-lru",
            "--bind", "127.0.0.1",
          ]

          port {
            container_port = 6379
            name           = "valkey"
          }

          volume_mount {
            name       = "valkey-data"
            mount_path = "/data"
          }

          resources {
            requests = {
              cpu    = "20m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "192Mi"
            }
          }
        }

        # TLS-terminating nginx
        container {
          name  = "nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "searxng-tls"
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
              memory = "256Mi"
            }
          }
        }

        # Tailscale sidecar — registers as the `searxng` tailnet node.
        container {
          name  = "tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "searxng-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.searxng_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.searxng_domain
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

        volume {
          name = "searxng-config-ro"
          config_map {
            name = kubernetes_config_map.searxng_config.metadata[0].name
          }
        }
        volume {
          name = "searxng-etc"
          empty_dir {}
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.searxng_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "searxng-tls"
          secret {
            secret_name = "searxng-tls"
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.searxng_secret_provider.manifest.metadata.name
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
        volume {
          name = "valkey-data"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.searxng_secret_provider,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "searxng" {
  metadata {
    name      = "searxng"
    namespace = kubernetes_namespace.searxng.metadata[0].name
  }
  spec {
    selector = {
      app = "searxng"
    }
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
  }
}
