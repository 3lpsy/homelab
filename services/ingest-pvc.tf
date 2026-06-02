# Dropzone PVC — owned by the `ingest` namespace. Shared by syncthing
# (writes from remote sync) and ingest-ui (writes from web upload + yt-dlp).
# navidrome-ingest in the navidrome namespace pulls files via HTTP from
# ingest-ui's /internal/dropzone/* endpoints rather than mounting this PVC
# directly — keeps namespace boundaries strict.
resource "kubernetes_persistent_volume_claim" "media_dropzone" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "media-dropzone"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.media_dropzone_size
      }
    }
  }
  wait_until_bound = false
}
