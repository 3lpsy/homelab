resource "kubernetes_persistent_volume_claim" "vault_data" {
  metadata {
    name      = "vault-data"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"

    resources {
      requests = {
        storage = "2Gi"
      }
    }
  }
  wait_until_bound = false
  lifecycle {
    prevent_destroy = true
  }
}
