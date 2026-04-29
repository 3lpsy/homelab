resource "kubernetes_persistent_volume_claim" "navidrome_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "navidrome-data"
    namespace = kubernetes_namespace.navidrome.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.navidrome_data_size
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_persistent_volume_claim" "navidrome_music" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "navidrome-music"
    namespace = kubernetes_namespace.navidrome.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.navidrome_music_size
      }
    }
  }
  wait_until_bound = false
}
