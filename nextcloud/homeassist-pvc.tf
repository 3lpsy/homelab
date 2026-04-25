resource "kubernetes_persistent_volume_claim" "homeassist_config" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "homeassist-config"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
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
