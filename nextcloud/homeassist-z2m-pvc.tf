resource "kubernetes_persistent_volume_claim" "homeassist_z2m_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "homeassist-z2m-data"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
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
