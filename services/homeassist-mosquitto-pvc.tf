resource "kubernetes_persistent_volume_claim" "homeassist_mosquitto_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "homeassist-mosquitto-data"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
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
