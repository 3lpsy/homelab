# Generate random passwords
resource "random_password" "nextcloud_admin" {
  length  = 32
  special = true
}

resource "random_password" "postgres_password" {
  length  = 32
  special = false
}

resource "random_password" "redis_password" {
  length  = 32
  special = false
}

resource "random_password" "collabora_password" {
  length  = 32
  special = false
}

# Generate HaRP shared key
resource "random_password" "harp_shared_key" {
  length  = 32
  special = false
}

# Pulled from registry.tf
resource "kubernetes_secret" "registry_pull_secret" {
  metadata {
    name      = "registry-pull-secret"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${var.registry_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}" = {
          username = "internal"
          password = random_password.registry_user_passwords["internal"].result
          auth     = base64encode("internal:${random_password.registry_user_passwords["internal"].result}")
        }
      }
    })
  }
}
