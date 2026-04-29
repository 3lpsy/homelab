resource "kubernetes_namespace" "jellyfin" {
  metadata {
    name = "jellyfin"
  }
}

resource "kubernetes_service_account" "jellyfin" {
  metadata {
    name      = "jellyfin"
    namespace = kubernetes_namespace.jellyfin.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_secret" "jellyfin_tailscale_state" {
  metadata {
    name      = "jellyfin-tailscale-state"
    namespace = kubernetes_namespace.jellyfin.metadata[0].name
  }
  type = "Opaque"

  lifecycle {
    ignore_changes = [data, type]
  }
}

resource "kubernetes_role" "jellyfin_tailscale" {
  metadata {
    name      = "jellyfin-tailscale"
    namespace = kubernetes_namespace.jellyfin.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["jellyfin-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "jellyfin_tailscale" {
  metadata {
    name      = "jellyfin-tailscale"
    namespace = kubernetes_namespace.jellyfin.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.jellyfin_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.jellyfin.metadata[0].name
    namespace = kubernetes_namespace.jellyfin.metadata[0].name
  }
}

resource "headscale_pre_auth_key" "jellyfin_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.jellyfin_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "jellyfin_tailscale_auth" {
  metadata {
    name      = "jellyfin-tailscale-auth"
    namespace = kubernetes_namespace.jellyfin.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.jellyfin_server.key
  }
}

module "jellyfin-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.jellyfin_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "vault_kv_secret_v2" "jellyfin_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "jellyfin/tls"
  data_json = jsonencode({
    fullchain_pem = module.jellyfin-tls.fullchain_pem
    privkey_pem   = module.jellyfin-tls.privkey_pem
  })

  # tls-rotator (nextcloud/tls-rotator.tf) owns rotation post-bootstrap.
  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "vault_policy" "jellyfin" {
  name = "jellyfin-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/jellyfin/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "jellyfin" {
  backend                          = "kubernetes"
  role_name                        = "jellyfin"
  bound_service_account_names      = [kubernetes_service_account.jellyfin.metadata[0].name]
  bound_service_account_namespaces = [kubernetes_namespace.jellyfin.metadata[0].name]
  token_policies                   = [vault_policy.jellyfin.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "jellyfin_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-jellyfin"
      namespace = kubernetes_namespace.jellyfin.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "jellyfin-tls"
          type       = "kubernetes.io/tls"
          data = [
            { objectName = "tls_crt", key = "tls.crt" },
            { objectName = "tls_key", key = "tls.key" },
          ]
        },
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "jellyfin"
        objects = yamlencode([
          {
            objectName = "tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/jellyfin/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/jellyfin/tls"
            secretKey  = "privkey_pem"
          },
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.jellyfin,
    vault_kubernetes_auth_backend_role.jellyfin,
    vault_kv_secret_v2.jellyfin_tls,
    vault_policy.jellyfin,
  ]
}
