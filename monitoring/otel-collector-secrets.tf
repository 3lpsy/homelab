resource "kubernetes_service_account" "otel_collector" {
  metadata {
    name      = "otel-collector"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  automount_service_account_token = true
}

# The otel-collector DaemonSet pulls from the in-cluster registry. Registry
# creds live in Vault (written by nextcloud/registry-secrets.tf). We read them
# here and synthesize a dockerconfigjson Secret for the DaemonSet to use as
# its imagePullSecret — no cross-deployment TF state read required.
data "vault_kv_secret_v2" "registry_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "registry/config"
}

locals {
  registry_fqdn              = "${var.registry_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  registry_internal_password = jsondecode(data.vault_kv_secret_v2.registry_config.data["users"])["internal"]
}

resource "kubernetes_secret" "otel_registry_pull_secret" {
  metadata {
    name      = "registry-pull-secret"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${local.registry_fqdn}" = {
          username = "internal"
          password = local.registry_internal_password
          auth     = base64encode("internal:${local.registry_internal_password}")
        }
      }
    })
  }
}

# k8sattributes processor needs to read pod/namespace/node metadata
resource "kubernetes_cluster_role" "otel_collector" {
  metadata { name = "otel-collector" }

  rule {
    api_groups = [""]
    resources  = ["pods", "namespaces", "nodes", "nodes/proxy"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["replicasets", "deployments", "daemonsets", "statefulsets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["extensions"]
    resources  = ["replicasets"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "otel_collector" {
  metadata { name = "otel-collector" }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.otel_collector.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.otel_collector.metadata[0].name
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
}

resource "vault_policy" "otel_collector" {
  name = "otel-collector-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/openobserve/config" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "otel_collector" {
  backend                          = "kubernetes"
  role_name                        = "otel-collector"
  bound_service_account_names      = ["otel-collector"]
  bound_service_account_namespaces = ["monitoring"]
  token_policies                   = [vault_policy.otel_collector.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "otel_collector_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-otel-collector"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "otel-openobserve-auth"
          type       = "Opaque"
          data = [
            { objectName = "basic_b64", key = "OO_AUTH" },
          ]
        },
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "otel-collector"
        objects = yamlencode([
          {
            objectName = "basic_b64"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/openobserve/config"
            secretKey  = "basic_b64"
          },
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.monitoring,
    vault_kubernetes_auth_backend_role.otel_collector,
    vault_kv_secret_v2.openobserve_config,
    vault_policy.otel_collector,
  ]
}
