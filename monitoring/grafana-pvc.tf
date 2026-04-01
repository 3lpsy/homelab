resource "kubernetes_persistent_volume_claim" "grafana_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "grafana-data"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.grafana_storage_size
      }
    }
  }
  wait_until_bound = false
}
