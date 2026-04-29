resource "kubernetes_namespace" "exitnode" {
  metadata {
    name = "exitnode"
  }
}

resource "kubernetes_service_account" "exitnode" {
  metadata {
    name      = "exitnode"
    namespace = kubernetes_namespace.exitnode.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_secret" "exitnode_tailscale_state" {
  for_each = toset([for name in keys(local.exitnode_names) : "exitnode-${name}-state"])

  metadata {
    name      = each.value
    namespace = kubernetes_namespace.exitnode.metadata[0].name
  }
  type = "Opaque"

  lifecycle {
    ignore_changes = [data, type]
  }
}

resource "kubernetes_role" "exitnode_tailscale" {
  metadata {
    name      = "exitnode-tailscale"
    namespace = kubernetes_namespace.exitnode.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    resource_names = concat(
      [for name in keys(local.exitnode_names) : "exitnode-${name}-state"],
      ["exitnode-haproxy-tailscale-state"],
    )
    verbs = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "exitnode_tailscale" {
  metadata {
    name      = "exitnode-tailscale"
    namespace = kubernetes_namespace.exitnode.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.exitnode_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.exitnode.metadata[0].name
    namespace = kubernetes_namespace.exitnode.metadata[0].name
  }
}

resource "headscale_pre_auth_key" "exitnode" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.exit_node_user
  reusable       = true
  time_to_expire = "3y"
  acl_tags       = ["tag:exitnode"]
}

resource "kubernetes_secret" "exitnode_tailscale_auth" {
  metadata {
    name      = "exitnode-tailscale-auth"
    namespace = kubernetes_namespace.exitnode.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.exitnode.key
  }
}

resource "kubernetes_secret" "exitnode_registry_pull_secret" {
  metadata {
    name      = "registry-pull-secret"
    namespace = kubernetes_namespace.exitnode.metadata[0].name
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

resource "kubernetes_secret" "exitnode_wg_config" {
  for_each = local.exitnode_names

  metadata {
    name      = "exitnode-wg-${each.key}"
    namespace = kubernetes_namespace.exitnode.metadata[0].name
  }
  type = "Opaque"
  data = {
    "wg0.conf" = local.exitnode_wg_configs[each.key]
  }
}
