resource "kubernetes_service" "collabora_internal" {
  metadata {
    name      = "collabora-internal"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    selector = {
      app = "collabora"
    }

    port {
      name        = "https"
      port        = 443
      target_port = 443
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_service" "harp" {
  metadata {
    name      = "appapi-harp"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    selector = {
      app = "appapi-harp"
    }

    port {
      name        = "http"
      port        = 8780
      target_port = 8780
    }

    port {
      name        = "frp"
      port        = 8782
      target_port = 8782
    }
  }
}


# Used for Nextcloud → Immich communication (e.g., integration_immich app)
# Unecessary?
resource "kubernetes_service" "immich_internal" {
  metadata {
    name      = "immich-internal"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  spec {
    selector = {
      app = "immich"
    }
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
    type = "ClusterIP"
  }
}

# Unnecssary?
resource "kubernetes_service" "pihole_internal" {
  metadata {
    name      = "pihole-internal"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }
  spec {
    selector = { app = "pihole" }
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
    type = "ClusterIP"
  }
}

# Required? Currently unused, node has registries.yml
resource "kubernetes_service" "registry_internal" {
  metadata {
    name      = "registry-internal"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }
  spec {
    selector = { app = "registry" }
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
    type = "ClusterIP"
  }
}


# Unnecessary. Remove
resource "kubernetes_service" "radicale_internal" {
  metadata {
    name      = "radicale-internal"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }
  spec {
    selector = { app = "radicale" }
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
    type = "ClusterIP"
  }
}
