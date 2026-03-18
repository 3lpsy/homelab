# RBAC for Prometheus Tailscale state secret

resource "kubernetes_role" "prometheus_tailscale" {
  metadata {
    name      = "prometheus-tailscale"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["create"]
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["prometheus-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "prometheus_tailscale" {
  metadata {
    name      = "prometheus-tailscale"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.prometheus_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.prometheus.metadata[0].name
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
}

# Headscale pre-auth key + K8s secret

resource "headscale_pre_auth_key" "prometheus_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.prometheus_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "prometheus_tailscale_auth" {
  metadata {
    name      = "prometheus-tailscale-auth"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.prometheus_server.key
  }
}

# Variable for OpenWrt target
