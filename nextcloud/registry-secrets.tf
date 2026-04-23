resource "kubernetes_namespace" "registry" {
  metadata {
    name = "registry"
  }
}

resource "kubernetes_service_account" "registry" {
  metadata {
    name      = "registry"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_role" "registry_tailscale" {
  metadata {
    name      = "registry-tailscale"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["create"]
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["registry-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "registry_tailscale" {
  metadata {
    name      = "registry-tailscale"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.registry_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.registry.metadata[0].name
    namespace = kubernetes_namespace.registry.metadata[0].name
  }
}

resource "random_password" "registry_user_passwords" {
  for_each = toset(var.registry_users)
  length   = 32
  special  = false
}

resource "headscale_pre_auth_key" "registry_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.registry_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "registry_tailscale_auth" {
  metadata {
    name      = "registry-tailscale-auth"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.registry_server.key
  }
}

module "registry-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.registry_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "vault_kv_secret_v2" "registry_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "registry/config"
  data_json = jsonencode({
    users = {
      for user in var.registry_users :
      user => random_password.registry_user_passwords[user].result
    }
  })
}

resource "vault_kv_secret_v2" "registry_htpasswd" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "registry/htpasswd"
  data_json = jsonencode({
    htpasswd = join("\n", [
      for user in var.registry_users :
      "${user}:${bcrypt(random_password.registry_user_passwords[user].result)}"
    ])
  })
  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "vault_kv_secret_v2" "registry_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "registry/tls"
  data_json = jsonencode({
    fullchain_pem = module.registry-tls.fullchain_pem
    privkey_pem   = module.registry-tls.privkey_pem
  })
}

resource "vault_policy" "registry" {
  name = "registry-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/registry/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "registry" {
  backend                          = "kubernetes"
  role_name                        = "registry"
  bound_service_account_names      = ["registry"]
  bound_service_account_namespaces = ["registry"]
  token_policies                   = [vault_policy.registry.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "registry_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-registry"
      namespace = kubernetes_namespace.registry.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "registry-htpasswd"
          type       = "Opaque"
          data = [
            {
              objectName = "htpasswd"
              key        = "htpasswd"
            }
          ]
        },
        {
          secretName = "registry-tls"
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
        roleName     = "registry"
        objects = yamlencode([
          {
            objectName = "htpasswd"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/registry/htpasswd"
            secretKey  = "htpasswd"
          },
          {
            objectName = "tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/registry/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/registry/tls"
            secretKey  = "privkey_pem"
          }
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.registry,
    vault_kubernetes_auth_backend_role.registry,
    vault_kv_secret_v2.registry_config,
    vault_kv_secret_v2.registry_htpasswd,
    vault_kv_secret_v2.registry_tls,
    vault_policy.registry
  ]
}

