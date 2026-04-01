resource "kubernetes_persistent_volume_claim" "nextcloud_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "nextcloud-data"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"

    resources {
      requests = {
        storage = "50Gi"
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_persistent_volume_claim" "postgres_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "postgres-data"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
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
