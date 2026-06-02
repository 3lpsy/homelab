resource "kubernetes_namespace" "builder" {
  metadata {
    name = "builder"
  }
}

resource "kubernetes_service_account" "builder" {
  metadata {
    name      = "builder"
    namespace = kubernetes_namespace.builder.metadata[0].name
  }
  automount_service_account_token = true
}

# Registry pull secret (reuses the "internal" registry user)

resource "kubernetes_secret" "builder_registry_pull_secret" {
  metadata {
    name      = "registry-pull-secret"
    namespace = kubernetes_namespace.builder.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${local.thunderbolt_registry}" = {
          username = "internal"
          password = random_password.registry_user_passwords["internal"].result
          auth     = base64encode("internal:${random_password.registry_user_passwords["internal"].result}")
        }
      }
    })
  }
}
