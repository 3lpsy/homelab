resource "kubernetes_persistent_volume_claim" "zitadel_postgres_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "zitadel-postgres-data"
    namespace = kubernetes_namespace.oidc.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.zitadel_postgres_storage_size
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_deployment" "zitadel_postgres" {
  metadata {
    name      = "zitadel-postgres"
    namespace = kubernetes_namespace.oidc.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "zitadel-postgres" }
    }

    template {
      metadata {
        labels = { app = "zitadel-postgres" }
        annotations = {
          "secret.reloader.stakater.com/reload" = module.zitadel_tls_vault.config_secret_name
        }
      }

      spec {
        service_account_name = kubernetes_service_account.zitadel.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "postgres_password"
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
          image = var.image_zitadel_postgres

          env {
            name  = "POSTGRES_DB"
            value = "zitadel"
          }
          env {
            name  = "POSTGRES_USER"
            value = "zitadel"
          }
          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.zitadel_tls_vault.config_secret_name
                key  = "postgres_password"
              }
            }
          }
          # PG18+ default PGDATA is /var/lib/postgresql/<MAJOR>/docker.
          # Set explicitly so a future image-default drift can't silently
          # land data on ephemeral fs again (the bug we hit on 2026-05-09).
          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/18/docker"
          }

          port {
            container_port = 5432
          }

          volume_mount {
            name       = "postgres-data"
            # PG18+: mount at parent dir; postgres creates /<MAJOR>/docker/ subdir.
            mount_path = "/var/lib/postgresql"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1000m", memory = "1Gi" }
          }

          liveness_probe {
            exec {
              command = ["pg_isready", "-U", "zitadel"]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
          readiness_probe {
            exec {
              command = ["pg_isready", "-U", "zitadel"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }

        volume {
          name = "postgres-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.zitadel_postgres_data.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.zitadel_tls_vault.spc_name
            }
          }
        }
      }
    }
  }

  depends_on = [
    module.zitadel_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "zitadel_postgres" {
  metadata {
    name      = "zitadel-postgres"
    namespace = kubernetes_namespace.oidc.metadata[0].name
  }
  spec {
    selector = { app = "zitadel-postgres" }
    port {
      port        = 5432
      target_port = 5432
    }
  }
}
