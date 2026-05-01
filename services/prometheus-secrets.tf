resource "kubernetes_service_account" "prometheus" {
  metadata {
    name      = "prometheus"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  # Prometheus needs the token to scrape kubelet/cadvisor
  automount_service_account_token = true
}

resource "kubernetes_cluster_role" "prometheus" {
  metadata { name = "prometheus" }

  rule {
    api_groups = [""]
    resources  = ["nodes", "nodes/proxy", "nodes/metrics", "services", "endpoints", "pods"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["extensions", "networking.k8s.io"]
    resources  = ["ingresses"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    non_resource_urls = ["/metrics", "/metrics/cadvisor"]
    verbs             = ["get"]
  }
}

resource "kubernetes_cluster_role_binding" "prometheus" {
  metadata { name = "prometheus" }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.prometheus.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.prometheus.metadata[0].name
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
}

resource "kubernetes_secret" "prometheus_tailscale_state" {
  metadata {
    name      = "prometheus-tailscale-state"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  type = "Opaque"

  lifecycle {
    ignore_changes = [data, type]
  }
}

resource "kubernetes_role" "prometheus_tailscale" {
  metadata {
    name      = "prometheus-tailscale"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
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

# Alertmanager reads its ntfy basic-auth password from a file mounted via
# Vault CSI. The password lives in Vault at ntfy/config (key
# password_prometheus, written by ntfy-secrets.tf). Reloader rotates the
# pod when the synced k8s Secret changes.
resource "vault_policy" "prometheus_alertmanager" {
  name = "prometheus-alertmanager-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/ntfy/config" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "prometheus_alertmanager" {
  backend                          = "kubernetes"
  role_name                        = "prometheus-alertmanager"
  bound_service_account_names      = ["prometheus"]
  bound_service_account_namespaces = ["monitoring"]
  token_policies                   = [vault_policy.prometheus_alertmanager.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "prometheus_alertmanager_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-prometheus-alertmanager"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "prometheus-alertmanager-ntfy-auth"
          type       = "Opaque"
          data = [
            { objectName = "ntfy_password", key = "ntfy_password" },
          ]
        },
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "prometheus-alertmanager"
        objects = yamlencode([
          {
            objectName = "ntfy_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/ntfy/config"
            secretKey  = "password_prometheus"
          },
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.monitoring,
    vault_kubernetes_auth_backend_role.prometheus_alertmanager,
    # Was vault_kv_secret_v2.ntfy_config (now lives inside the
    # ntfy_tls_vault module). Depend on the whole module so the config
    # write completes before this SPC reads from the same path.
    module.ntfy_tls_vault,
    vault_policy.prometheus_alertmanager,
  ]
}
