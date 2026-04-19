resource "kubernetes_deployment" "thunderbolt_mongo" {
  metadata {
    name      = "thunderbolt-mongo"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "thunderbolt-mongo"
      }
    }

    template {
      metadata {
        labels = {
          app = "thunderbolt-mongo"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.thunderbolt.metadata[0].name

        container {
          name  = "mongo"
          image = var.image_mongo

          args = ["--replSet", "rs0", "--bind_ip_all", "--quiet"]

          port {
            container_port = 27017
          }

          volume_mount {
            name       = "mongo-data"
            mount_path = "/data/db"
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
            exec {
              command = ["mongosh", "--quiet", "--eval", "db.adminCommand('ping').ok"]
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        volume {
          name = "mongo-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.thunderbolt_mongo_data.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "thunderbolt_mongo" {
  metadata {
    name      = "thunderbolt-mongo"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }
  spec {
    selector = {
      app = "thunderbolt-mongo"
    }
    port {
      port        = 27017
      target_port = 27017
    }
  }
}

# One-shot replica-set init. Idempotent: rs.status() check short-circuits.
# Uses timestamp() in the name so each `terraform apply` creates a new job and
# old completed ones accumulate — clean up periodically:
#   kubectl delete jobs -n thunderbolt --field-selector status.successful=1
resource "kubernetes_job" "thunderbolt_mongo_rs_init" {
  metadata {
    name      = "thunderbolt-mongo-rs-init-${substr(sha1(timestamp()), 0, 8)}"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  spec {
    backoff_limit = 5
    template {
      metadata {
        labels = {
          app = "thunderbolt-mongo-rs-init"
        }
      }
      spec {
        restart_policy       = "OnFailure"
        service_account_name = kubernetes_service_account.thunderbolt.metadata[0].name

        container {
          name  = "mongo-rs-init"
          image = var.image_mongo
          command = [
            "bash", "-c",
            "until mongosh --host thunderbolt-mongo:27017 --eval 'db.adminCommand({ping:1})' >/dev/null 2>&1; do echo waiting for mongo; sleep 2; done; mongosh --host thunderbolt-mongo:27017 --eval 'try{rs.status().ok&&quit(0)}catch{}rs.initiate({_id:\"rs0\",version:1,members:[{_id:0,host:\"thunderbolt-mongo:27017\"}]})'"
          ]
        }
      }
    }
  }

  wait_for_completion = false

  lifecycle {
    ignore_changes = [metadata[0].name]
  }

  depends_on = [
    kubernetes_deployment.thunderbolt_mongo,
    kubernetes_service.thunderbolt_mongo,
  ]
}
