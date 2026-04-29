resource "kubernetes_persistent_volume_claim" "litellm_postgres_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "litellm-postgres-data"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = "5Gi"
      }
    }
  }
  wait_until_bound = false
}
