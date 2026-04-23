resource "kubernetes_namespace" "pihole" {
  metadata {
    name = "pihole"
  }
}

resource "kubernetes_service_account" "pihole" {
  metadata {
    name      = "pihole"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_role" "pihole_tailscale" {
  metadata {
    name      = "pihole-tailscale"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["create"]
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["pihole-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "pihole_tailscale" {
  metadata {
    name      = "pihole-tailscale"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.pihole_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.pihole.metadata[0].name
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }
}

resource "random_password" "pihole_password" {
  length  = 32
  special = false
}

resource "headscale_pre_auth_key" "pihole_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.pihole_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "pihole_tailscale_auth" {
  metadata {
    name      = "pihole-tailscale-auth"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.pihole_server.key
  }
}

module "pihole-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.pihole_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "vault_kv_secret_v2" "pihole_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "pihole/config"
  data_json = jsonencode({
    admin_password = random_password.pihole_password.result
  })
}

resource "vault_kv_secret_v2" "pihole_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "pihole/tls"
  data_json = jsonencode({
    fullchain_pem = module.pihole-tls.fullchain_pem
    privkey_pem   = module.pihole-tls.privkey_pem
  })
}

resource "vault_policy" "pihole" {
  name = "pihole-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/pihole/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "pihole" {
  backend                          = "kubernetes"
  role_name                        = "pihole"
  bound_service_account_names      = ["pihole"]
  bound_service_account_namespaces = ["pihole"]
  token_policies                   = [vault_policy.pihole.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "pihole_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-pihole"
      namespace = kubernetes_namespace.pihole.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "pihole-secrets"
          type       = "Opaque"
          data = [
            {
              objectName = "admin_password"
              key        = "admin_password"
            }
          ]
        },
        {
          secretName = "pihole-tls"
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
        roleName     = "pihole"
        objects = yamlencode([
          {
            objectName = "admin_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/pihole/config"
            secretKey  = "admin_password"
          },
          {
            objectName = "tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/pihole/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/pihole/tls"
            secretKey  = "privkey_pem"
          }
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.pihole,
    vault_kubernetes_auth_backend_role.pihole,
    vault_kv_secret_v2.pihole_config,
    vault_kv_secret_v2.pihole_tls,
    vault_policy.pihole
  ]
}

