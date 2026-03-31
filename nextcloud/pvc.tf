resource "kubernetes_persistent_volume_claim" "nextcloud_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "nextcloud-data"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
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

resource "kubernetes_persistent_volume_claim" "postgres_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "postgres-data"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"

    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
  wait_until_bound = false
}




# Immich Storage / currently not really used as using external immich lib
resource "kubernetes_persistent_volume_claim" "immich_upload" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "immich-upload"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
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

resource "kubernetes_persistent_volume_claim" "immich_postgres_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "immich-postgres-data"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_persistent_volume_claim" "registry_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "registry-data"
    namespace = kubernetes_namespace.registry.metadata[0].name
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

# Pihole
resource "kubernetes_persistent_volume_claim" "pihole_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "pihole-data"
    namespace = kubernetes_namespace.pihole.metadata[0].name
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

resource "kubernetes_persistent_volume_claim" "radicale_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "radicale-data"
    namespace = kubernetes_namespace.radicale.metadata[0].name
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
