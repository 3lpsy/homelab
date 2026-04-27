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

locals {
  builder_tailscale_state_secrets = [
    "mcp-searxng-builder-tailscale-state",
    "mcp-filesystem-builder-tailscale-state",
    "mcp-memory-builder-tailscale-state",
    "mcp-prometheus-builder-tailscale-state",
    "mcp-time-builder-tailscale-state",
    "mcp-litellm-builder-tailscale-state",
    "mcp-k8s-builder-tailscale-state",
    "mcp-k8s-auth-gate-builder-tailscale-state",
    "thunderbolt-frontend-builder-tailscale-state",
    "thunderbolt-backend-builder-tailscale-state",
    "nextcloud-builder-tailscale-state",
    "exitnode-tinyproxy-builder-tailscale-state",
    "searxng-ranker-builder-tailscale-state",
    "otel-collector-builder-tailscale-state",
    "tls-rotator-builder-tailscale-state",
  ]
}

resource "kubernetes_secret" "builder_tailscale_state" {
  for_each = toset(local.builder_tailscale_state_secrets)

  metadata {
    name      = each.value
    namespace = kubernetes_namespace.builder.metadata[0].name
  }
  type = "Opaque"

  lifecycle {
    ignore_changes = [data, type]
  }
}

resource "kubernetes_role" "builder_tailscale" {
  metadata {
    name      = "builder-tailscale"
    namespace = kubernetes_namespace.builder.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = local.builder_tailscale_state_secrets
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "builder_tailscale" {
  metadata {
    name      = "builder-tailscale"
    namespace = kubernetes_namespace.builder.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.builder_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.builder.metadata[0].name
    namespace = kubernetes_namespace.builder.metadata[0].name
  }
}

# Headscale preauth (shared across per-service build jobs; ephemeral)

resource "headscale_pre_auth_key" "builder" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.builder_user
  reusable       = true
  ephemeral      = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "builder_tailscale_auth" {
  metadata {
    name      = "builder-tailscale-auth"
    namespace = kubernetes_namespace.builder.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.builder.key
  }
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
