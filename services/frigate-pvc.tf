resource "kubernetes_persistent_volume_claim" "frigate_config" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "frigate-config"
    namespace = kubernetes_namespace.frigate.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.frigate_config_size
      }
    }
  }
  wait_until_bound = false
}

# Recordings + clip exports live here. Sized large because Frigate continuous
# recording fills disk fast; split from `frigate-config` so swapping in a
# network-backed storage class (TrueNAS / democratic-csi) later only touches
# this PVC, not the small config one.
resource "kubernetes_persistent_volume_claim" "frigate_recordings" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "frigate-recordings"
    namespace = kubernetes_namespace.frigate.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.frigate_recordings_size
      }
    }
  }
  wait_until_bound = false
}
