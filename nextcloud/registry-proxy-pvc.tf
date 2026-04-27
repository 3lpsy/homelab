resource "kubernetes_persistent_volume_claim" "registry_proxy_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "registry-proxy-data"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
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
