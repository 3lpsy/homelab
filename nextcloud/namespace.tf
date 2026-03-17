# Namespaces, Service Accounts, Roles, Role Bindings

# Create namespace for Nextcloud, harp, collabora, and immich
resource "kubernetes_namespace" "nextcloud" {
  metadata {
    name = "nextcloud"
  }
}

# Service Account for Nextcloud
resource "kubernetes_service_account" "nextcloud" {
  metadata {
    name      = "nextcloud"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  automount_service_account_token = false
}

# Role for Tailscale
resource "kubernetes_role" "tailscale" {
  metadata {
    name      = "tailscale"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["create"]
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["tailscale-state", "collabora-tailscale-state", "immich-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "tailscale" {
  metadata {
    name      = "tailscale"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.nextcloud.metadata[0].name
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
}

# Pihole Namespace
resource "kubernetes_namespace" "pihole" {
  metadata {
    name = "pihole"
  }
}
resource "kubernetes_service_account" "pihole" {
  metadata {
    name      = "pihole"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }
  automount_service_account_token = false
}
resource "kubernetes_role" "pihole_tailscale" {
  metadata {
    name      = "pihole-tailscale"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["create"]
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["pihole-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}
resource "kubernetes_role_binding" "pihole_tailscale" {
  metadata {
    name      = "pihole-tailscale"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.pihole_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.pihole.metadata[0].name
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }
}

# Registry
resource "kubernetes_namespace" "registry" {
  metadata {
    name = "registry"
  }
}

resource "kubernetes_service_account" "registry" {
  metadata {
    name      = "registry"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_role" "registry_tailscale" {
  metadata {
    name      = "registry-tailscale"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["create"]
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["registry-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "registry_tailscale" {
  metadata {
    name      = "registry-tailscale"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.registry_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.registry.metadata[0].name
    namespace = kubernetes_namespace.registry.metadata[0].name
  }
}

# Radicale
resource "kubernetes_namespace" "radicale" {
  metadata {
    name = "radicale"
  }
}
resource "kubernetes_service_account" "radicale" {
  metadata {
    name      = "radicale"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_role" "radicale_tailscale" {
  metadata {
    name      = "radicale-tailscale"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["create"]
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["radicale-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "radicale_tailscale" {
  metadata {
    name      = "radicale-tailscale"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.radicale_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.radicale.metadata[0].name
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }
}
