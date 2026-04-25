resource "kubernetes_namespace" "homeassist" {
  metadata {
    name = "homeassist"
  }
}

resource "kubernetes_service_account" "homeassist" {
  metadata {
    name      = "homeassist"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_role" "homeassist_tailscale" {
  metadata {
    name      = "homeassist-tailscale"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["create"]
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["homeassist-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "homeassist_tailscale" {
  metadata {
    name      = "homeassist-tailscale"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.homeassist_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.homeassist.metadata[0].name
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
}

resource "headscale_pre_auth_key" "homeassist_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.homeassist_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "homeassist_tailscale_auth" {
  metadata {
    name      = "homeassist-tailscale-auth"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.homeassist_server.key
  }
}

resource "random_password" "homeassist_admin" {
  length  = 32
  special = false
}

module "homeassist-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.homeassist_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "vault_kv_secret_v2" "homeassist_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "homeassist/tls"
  data_json = jsonencode({
    fullchain_pem = module.homeassist-tls.fullchain_pem
    privkey_pem   = module.homeassist-tls.privkey_pem
  })

  # tls-rotator (nextcloud/tls-rotator.tf) owns rotation post-bootstrap.
  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "vault_kv_secret_v2" "homeassist_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "homeassist/config"
  data_json = jsonencode({
    admin_password = random_password.homeassist_admin.result
  })
}

resource "vault_policy" "homeassist" {
  name = "homeassist-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/homeassist/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "homeassist" {
  backend                          = "kubernetes"
  role_name                        = "homeassist"
  bound_service_account_names      = ["homeassist"]
  bound_service_account_namespaces = ["homeassist"]
  token_policies                   = [vault_policy.homeassist.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "homeassist_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-homeassist"
      namespace = kubernetes_namespace.homeassist.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "homeassist-secrets"
          type       = "Opaque"
          data = [
            {
              objectName = "admin_password"
              key        = "admin_password"
            }
          ]
        },
        {
          secretName = "homeassist-tls"
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
        roleName     = "homeassist"
        objects = yamlencode([
          {
            objectName = "admin_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/homeassist/config"
            secretKey  = "admin_password"
          },
          {
            objectName = "tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/homeassist/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/homeassist/tls"
            secretKey  = "privkey_pem"
          }
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.homeassist,
    vault_kubernetes_auth_backend_role.homeassist,
    vault_kv_secret_v2.homeassist_config,
    vault_kv_secret_v2.homeassist_tls,
    vault_policy.homeassist
  ]
}
