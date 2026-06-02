terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    headscale = {
      source  = "awlsring/headscale"
      version = "~> 0.5.0"
    }
  }
}

locals {
  role_name         = coalesce(var.role_name, "${var.name}-tailscale")
  state_secret_name = coalesce(var.state_secret_name, "${var.name}-tailscale-state")
  auth_secret_name  = coalesce(var.auth_secret_name, "${var.name}-tailscale-auth")
}

resource "kubernetes_secret" "tailscale_state" {
  metadata {
    name      = local.state_secret_name
    namespace = var.namespace
  }
  type = "Opaque"

  lifecycle {
    ignore_changes = [data, type]
  }
}

resource "kubernetes_role" "tailscale" {
  count = var.manage_role ? 1 : 0

  metadata {
    name      = local.role_name
    namespace = var.namespace
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = [kubernetes_secret.tailscale_state.metadata[0].name]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "tailscale" {
  count = var.manage_role ? 1 : 0

  metadata {
    name      = local.role_name
    namespace = var.namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.tailscale[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = var.service_account_name
    namespace = var.namespace
  }
}

resource "headscale_pre_auth_key" "this" {
  user           = var.tailnet_user_id
  reusable       = var.reusable
  time_to_expire = var.time_to_expire
}

resource "kubernetes_secret" "tailscale_auth" {
  metadata {
    name      = local.auth_secret_name
    namespace = var.namespace
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.this.key
  }
}
