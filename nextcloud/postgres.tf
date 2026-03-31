resource "kubernetes_deployment" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "postgres"
      }
    }

    template {
      metadata {
        labels = {
          app = "postgres"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name

        container {
          name  = "postgres"
          image = "postgres:15-alpine"

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

          port {
            container_port = 5432
          }

          volume_mount {
            name       = "postgres-data"
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
              memory = "256Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }

          liveness_probe {
            exec {
              command = ["pg_isready", "-U", "nextcloud"]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          readiness_probe {
            exec {
              command = ["pg_isready", "-U", "nextcloud"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }

        volume {
          name = "postgres-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.postgres_data.metadata[0].name
          }
        }

        # CSI sync?
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

resource "kubernetes_service" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    selector = {
      app = "postgres"
    }

    port {
      port        = 5432
      target_port = 5432
    }
  }
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
          image = "busybox:latest"
          command = [
            "sh", "-c",
            <<-EOT
              echo 'Waiting for Immich secrets to sync from Vault...'
              TIMEOUT=300
              ELAPSED=0
              until [ -f /mnt/secrets/immich_db_password ]; do
                if [ $ELAPSED -ge $TIMEOUT ]; then
                  echo "Timeout waiting for secrets after $${TIMEOUT}s"
                  exit 1
                fi
                echo "Still waiting... ($${ELAPSED}s)"
                sleep 5
                ELAPSED=$((ELAPSED + 5))
              done
              echo 'Immich secrets synced successfully!'
            EOT
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        container {
          name  = "postgres"
          image = "ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0"

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
              memory = "256Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
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
