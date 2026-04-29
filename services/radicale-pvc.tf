resource "kubernetes_persistent_volume_claim" "radicale_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "radicale-data"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
  wait_until_bound = false
}
