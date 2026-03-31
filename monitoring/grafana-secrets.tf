resource "kubernetes_service_account" "grafana" {
  metadata {
    name      = "grafana"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_role" "grafana_tailscale" {
  metadata {
    name      = "grafana-tailscale"
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
    resource_names = ["grafana-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "grafana_tailscale" {
  metadata {
    name      = "grafana-tailscale"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.grafana_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.grafana.metadata[0].name
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
}

resource "headscale_pre_auth_key" "grafana_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.grafana_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "grafana_tailscale_auth" {
  metadata {
    name      = "grafana-tailscale-auth"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.grafana_server.key
  }
}

module "grafana-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.grafana_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "random_password" "grafana_admin" {
  length  = 32
  special = false
}

resource "vault_kv_secret_v2" "grafana_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "grafana/config"
  data_json = jsonencode({
    admin_password = random_password.grafana_admin.result
  })
}

resource "vault_kv_secret_v2" "grafana_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "grafana/tls"
  data_json = jsonencode({
    fullchain_pem = module.grafana-tls.fullchain_pem
    privkey_pem   = module.grafana-tls.privkey_pem
  })
}

resource "vault_policy" "grafana" {
  name = "grafana-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/grafana/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "grafana" {
  backend                          = "kubernetes"
  role_name                        = "grafana"
  bound_service_account_names      = ["grafana"]
  bound_service_account_namespaces = ["monitoring"]
  token_policies                   = [vault_policy.grafana.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "grafana_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-grafana"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "grafana-secrets"
          type       = "Opaque"
          data = [
            {
              objectName = "admin_password"
              key        = "admin_password"
            }
          ]
        },
        {
          secretName = "grafana-tls"
          type       = "kubernetes.io/tls"
          data = [
            {
              objectName = "tls_crt"
              key        = "tls.crt"
            },
            {
              objectName = "tls_key"
              key        = "tls.key"
            }
          ]
        }
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "grafana"
        objects = yamlencode([
          {
            objectName = "admin_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/grafana/config"
            secretKey  = "admin_password"
          },
          {
            objectName = "tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/grafana/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/grafana/tls"
            secretKey  = "privkey_pem"
          }
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.monitoring,
    vault_kubernetes_auth_backend_role.grafana,
    vault_kv_secret_v2.grafana_config,
    vault_kv_secret_v2.grafana_tls,
    vault_policy.grafana
  ]
}
