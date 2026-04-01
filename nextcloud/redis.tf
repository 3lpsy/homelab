resource "kubernetes_deployment" "redis" {
  metadata {
    name      = "redis"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "redis"
      }
    }

    template {
      metadata {
        labels = {
          app = "redis"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name

        container {
          name  = "redis"
          image = var.image_redis

          command = [
            "redis-server",
            "--requirepass",
            "$(REDIS_PASSWORD)"
          ]

          env {
            name = "REDIS_PASSWORD"
            value_from {
              secret_key_ref {
                name = "nextcloud-secrets"
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
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          liveness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 30
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

resource "kubernetes_service" "redis" {
  metadata {
    name      = "redis"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    selector = {
      app = "redis"
    }

    port {
      port        = 6379
      target_port = 6379
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
