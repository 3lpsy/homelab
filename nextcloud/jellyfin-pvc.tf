resource "kubernetes_persistent_volume_claim" "jellyfin_config" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "jellyfin-config"
    namespace = kubernetes_namespace.jellyfin.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.jellyfin_config_size
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_persistent_volume_claim" "jellyfin_cache" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "jellyfin-cache"
    namespace = kubernetes_namespace.jellyfin.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.jellyfin_cache_size
      }
    }
  }
  wait_until_bound = false
}
