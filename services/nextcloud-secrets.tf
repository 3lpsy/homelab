# Shared namespace resources (serves nextcloud, collabora, immich)

resource "kubernetes_namespace" "nextcloud" {
  metadata {
    name = "nextcloud"
  }
}

resource "kubernetes_service_account" "nextcloud" {
  metadata {
    name      = "nextcloud"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_secret" "tailscale_state" {
  for_each = toset(["tailscale-state", "collabora-tailscale-state"])

  metadata {
    name      = each.value
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  type = "Opaque"

  lifecycle {
    ignore_changes = [data, type]
  }
}

resource "kubernetes_role" "tailscale" {
  metadata {
    name      = "tailscale"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["tailscale-state", "collabora-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "tailscale" {
  metadata {
    name      = "tailscale"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.nextcloud.metadata[0].name
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
}

resource "kubernetes_secret" "registry_pull_secret" {
  metadata {
    name      = "registry-pull-secret"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${var.registry_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}" = {
          username = "internal"
          password = random_password.registry_user_passwords["internal"].result
          auth     = base64encode("internal:${random_password.registry_user_passwords["internal"].result}")
        }
      }
    })
  }
}

# Nextcloud secrets

resource "random_password" "nextcloud_admin" {
  length  = 32
  special = true
}

resource "random_password" "postgres_password" {
  length  = 32
  special = false
}

resource "random_password" "redis_password" {
  length  = 32
  special = false
}

resource "headscale_pre_auth_key" "nextcloud_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.nextcloud_server_user
  reusable       = true
  time_to_expire = "1y"
}

resource "kubernetes_secret" "tailscale_auth" {
  metadata {
    name      = "tailscale-auth"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  type = "Opaque"

  data = {
    TS_AUTHKEY = headscale_pre_auth_key.nextcloud_server.key
  }
}

module "nextcloud-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = {
    acme = acme
  }
}

resource "vault_kv_secret_v2" "nextcloud_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "nextcloud/tls"

  data_json = jsonencode({
    fullchain_pem = module.nextcloud-tls.fullchain_pem
    privkey_pem   = module.nextcloud-tls.privkey_pem
  })

  # tls-rotator (services/tls-rotator.tf) owns rotation post-bootstrap.
  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "vault_kv_secret_v2" "nextcloud" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "nextcloud/config"

  data_json = jsonencode({
    admin_password     = random_password.nextcloud_admin.result
    postgres_password  = random_password.postgres_password.result
    redis_password     = random_password.redis_password.result
    collabora_password = random_password.collabora_password.result
  })
}

resource "vault_policy" "nextcloud" {
  name = "nextcloud-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "nextcloud" {
  backend                          = "kubernetes"
  role_name                        = "nextcloud"
  bound_service_account_names      = ["nextcloud"]
  bound_service_account_namespaces = ["nextcloud"]
  token_policies                   = [vault_policy.nextcloud.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "nextcloud_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-nextcloud"
      namespace = kubernetes_namespace.nextcloud.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "nextcloud-secrets"
          type       = "Opaque"
          data = [
            {
              objectName = "admin_password"
              key        = "admin_password"
            },
            {
              objectName = "postgres_password"
              key        = "postgres_password"
            },
            {
              objectName = "redis_password"
              key        = "redis_password"
            },
            {
              objectName = "collabora_password"
              key        = "collabora_password"
            }
          ]
        },
        {
          secretName = "nextcloud-tls"
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
        },
        {
          secretName = "collabora-tls"
          type       = "kubernetes.io/tls"
          data = [
            {
              objectName = "collabora_tls_crt"
              key        = "tls.crt"
            },
            {
              objectName = "collabora_tls_key"
              key        = "tls.key"
            }
          ]
        }
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "nextcloud"
        objects = yamlencode([
          {
            objectName = "admin_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/config"
            secretKey  = "admin_password"
          },
          {
            objectName = "postgres_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/config"
            secretKey  = "postgres_password"
          },
          {
            objectName = "redis_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/config"
            secretKey  = "redis_password"
          },
          {
            objectName = "tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/tls"
            secretKey  = "privkey_pem"
          },
          {
            objectName = "collabora_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/config"
            secretKey  = "collabora_password"
          },
          {
            objectName = "collabora_tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/collabora-tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "collabora_tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/collabora-tls"
            secretKey  = "privkey_pem"
          }
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.nextcloud,
    vault_kubernetes_auth_backend_role.nextcloud,
    vault_kv_secret_v2.nextcloud,
    vault_kv_secret_v2.nextcloud_tls,
    vault_kv_secret_v2.collabora_tls
  ]
}

