resource "kubernetes_persistent_volume_claim" "immich_upload" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "immich-upload"
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

resource "kubernetes_persistent_volume_claim" "immich_postgres_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "immich-postgres-data"
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
