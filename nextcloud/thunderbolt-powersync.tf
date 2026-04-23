resource "kubernetes_deployment" "thunderbolt_powersync" {
  metadata {
    name      = "thunderbolt-powersync"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "thunderbolt-powersync"
      }
    }

    template {
      metadata {
        labels = {
          app = "thunderbolt-powersync"
        }
        annotations = {
          "config-hash" = sha1(kubernetes_config_map.thunderbolt_powersync_config.data["config.yaml"])
        }
      }

      spec {
        service_account_name = kubernetes_service_account.thunderbolt.metadata[0].name

        container {
          name  = "powersync"
          image = var.image_powersync

          args = ["start", "-r", "unified"]

          env {
            name  = "POWERSYNC_CONFIG_PATH"
            value = "/config/config.yaml"
          }


          port {
            container_port = 8080
            name           = "http"
          }

          volume_mount {
            name       = "powersync-config"
            mount_path = "/config"
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
        }

        volume {
          name = "powersync-config"
          config_map {
            name = kubernetes_config_map.thunderbolt_powersync_config.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment.thunderbolt_postgres,
    kubernetes_job.thunderbolt_mongo_rs_init,
  ]
}

resource "kubernetes_service" "thunderbolt_powersync" {
  metadata {
    name      = "thunderbolt-powersync"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }
  spec {
    selector = {
      app = "thunderbolt-powersync"
    }
    port {
      port        = 8080
      target_port = 8080
    }
  }
}
