resource "kubernetes_deployment" "immich_machine_learning" {
  metadata {
    name      = "immich-machine-learning"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "immich-machine-learning"
      }
    }

    template {
      metadata {
        labels = {
          app = "immich-machine-learning"
        }
      }

      spec {
        container {
          name  = "machine-learning"
          image = var.image_immich_ml

          port {
            container_port = 3003
          }

          volume_mount {
            name       = "model-cache"
            mount_path = "/cache"
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
            tcp_socket {
              port = 3003
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 10
          }

          readiness_probe {
            tcp_socket {
              port = 3003
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        volume {
          name = "model-cache"
          empty_dir {}
        }
      }
    }
  }
}

resource "kubernetes_service" "immich_machine_learning" {
  metadata {
    name      = "immich-machine-learning"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  spec {
    selector = {
      app = "immich-machine-learning"
    }
    port {
      port        = 3003
      target_port = 3003
    }
  }
}

resource "kubernetes_deployment" "immich" {
  metadata {
    name      = "immich"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "immich"
      }
    }

    template {
      metadata {
        labels = {
          app = "immich"
        }
        annotations = {
          "nginx-config-hash"                   = sha1(kubernetes_config_map.immich_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "immich-secrets,immich-tls"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "immich_db_password"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Immich Server
        container {
          name  = "immich-server"
          image = var.image_immich_server

          port {
            container_port = 2283
            name           = "http"
          }

          env {
            name  = "DB_HOSTNAME"
            value = "immich-postgres"
          }
          env {
            name  = "DB_PORT"
            value = "5432"
          }
          env {
            name  = "DB_USERNAME"
            value = "immich"
          }
          env {
            name = "DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = "immich-secrets"
                key  = "db_password"
              }
            }
          }
          env {
            name  = "DB_DATABASE_NAME"
            value = "immich"
          }

          env {
            name  = "REDIS_HOSTNAME"
            value = "immich-redis"
          }
          env {
            name  = "REDIS_PORT"
            value = "6379"
          }
          env {
            name = "REDIS_PASSWORD"
            value_from {
              secret_key_ref {
                name = "immich-secrets"
                key  = "redis_password"
              }
            }
          }

          env {
            name  = "IMMICH_MACHINE_LEARNING_URL"
            value = "http://immich-machine-learning:3003"
          }

          env {
            name  = "TZ"
            value = "America/Chicago"
          }

          volume_mount {
            name       = "immich-upload"
            mount_path = "/data"
          }

          volume_mount {
            name       = "localtime"
            mount_path = "/etc/localtime"
            read_only  = true
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
              path = "/api/server/ping"
              port = 2283
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 10
          }

          readiness_probe {
            http_get {
              path = "/api/server/ping"
              port = 2283
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        # Immich Volumes
        volume {
          name = "immich-upload"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.immich_upload.metadata[0].name
          }
        }
        volume {
          name = "localtime"
          host_path {
            path = "/etc/localtime"
            type = "File"
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.immich_secret_provider.manifest.metadata.name
            }
          }
        }

        # Nginx
        container {
          name  = "immich-nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "immich-tls"
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
              memory = "2Gi"
            }
          }
        }

        # Nginx Volumes
        volume {
          name = "immich-tls"
          secret {
            secret_name = "immich-tls"
          }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.immich_nginx_config.metadata[0].name
          }
        }

        # Tailscale
        container {
          name  = "immich-tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "immich-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.immich_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.immich_domain
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
    kubernetes_manifest.immich_secret_provider,
    kubernetes_deployment.immich_postgres,
    kubernetes_deployment.immich_redis,
    kubernetes_deployment.immich_machine_learning
  ]
}

resource "kubernetes_deployment" "immich_postgres" {
  metadata {
    name      = "immich-postgres"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "immich-postgres"
      }
    }

    template {
      metadata {
        labels = {
          app = "immich-postgres"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "immich_db_password"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        container {
          name  = "postgres"
          image = var.image_immich_postgres

          env {
            name  = "POSTGRES_DB"
            value = "immich"
          }
          env {
            name  = "POSTGRES_USER"
            value = "immich"
          }
          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = "immich-secrets"
                key  = "db_password"
              }
            }
          }
          env {
            name  = "POSTGRES_INITDB_ARGS"
            value = "--data-checksums"
          }

          port {
            container_port = 5432
          }

          volume_mount {
            name       = "immich-postgres-data"
            mount_path = "/var/lib/postgresql/data"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "2Gi"
            }
          }

          liveness_probe {
            exec {
              command = ["pg_isready", "-U", "immich", "-d", "immich"]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          readiness_probe {
            exec {
              command = ["pg_isready", "-U", "immich", "-d", "immich"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }

        volume {
          name = "immich-postgres-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.immich_postgres_data.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.immich_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.immich_secret_provider
  ]
}

resource "kubernetes_service" "immich_postgres" {
  metadata {
    name      = "immich-postgres"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  spec {
    selector = {
      app = "immich-postgres"
    }
    port {
      port        = 5432
      target_port = 5432
    }
  }
}

resource "kubernetes_deployment" "immich_redis" {
  metadata {
    name      = "immich-redis"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "immich-redis"
      }
    }

    template {
      metadata {
        labels = {
          app = "immich-redis"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "immich_redis_password"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        container {
          name  = "valkey"
          image = var.image_valkey

          command = [
            "redis-server",
            "--requirepass",
            "$(REDIS_PASSWORD)"
          ]

          env {
            name = "REDIS_PASSWORD"
            value_from {
              secret_key_ref {
                name = "immich-secrets"
                key  = "redis_password"
              }
            }
          }

          port {
            container_port = 6379
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "256Mi"
            }
          }

          liveness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          readiness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }

        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.immich_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.immich_secret_provider
  ]
}

resource "kubernetes_service" "immich_redis" {
  metadata {
    name      = "immich-redis"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  spec {
    selector = {
      app = "immich-redis"
    }
    port {
      port        = 6379
      target_port = 6379
    }
  }
}
