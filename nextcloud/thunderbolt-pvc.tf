resource "kubernetes_persistent_volume_claim" "thunderbolt_postgres_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "thunderbolt-postgres-data"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = "20Gi"
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_persistent_volume_claim" "thunderbolt_mongo_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "thunderbolt-mongo-data"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
  wait_until_bound = false
}
