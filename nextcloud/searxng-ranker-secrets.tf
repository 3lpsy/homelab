resource "kubernetes_service_account" "searxng_ranker" {
  metadata {
    name      = "searxng-ranker"
    namespace = kubernetes_namespace.searxng.metadata[0].name
  }
  automount_service_account_token = true
}

# Ranker needs to read + mutate the searxng-config ConfigMap and patch the
# searxng Deployment's pod-template annotations (to trigger rolling restart).
# Scoped to those two resources by name.
resource "kubernetes_role" "searxng_ranker" {
  metadata {
    name      = "searxng-ranker"
    namespace = kubernetes_namespace.searxng.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["configmaps"]
    resource_names = ["searxng-config"]
    verbs          = ["get", "patch", "update"]
  }

  rule {
    api_groups     = ["apps"]
    resources      = ["deployments"]
    resource_names = ["searxng"]
    verbs          = ["get", "patch"]
  }
}

resource "kubernetes_role_binding" "searxng_ranker" {
  metadata {
    name      = "searxng-ranker"
    namespace = kubernetes_namespace.searxng.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.searxng_ranker.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.searxng_ranker.metadata[0].name
    namespace = kubernetes_namespace.searxng.metadata[0].name
  }
}

resource "kubernetes_secret" "searxng_registry_pull_secret" {
  metadata {
    name      = "registry-pull-secret"
    namespace = kubernetes_namespace.searxng.metadata[0].name
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
