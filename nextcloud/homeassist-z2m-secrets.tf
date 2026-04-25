resource "kubernetes_service_account" "homeassist_z2m" {
  metadata {
    name      = "homeassist-z2m"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_role" "homeassist_z2m_tailscale" {
  metadata {
    name      = "homeassist-z2m-tailscale"
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
    resource_names = ["homeassist-z2m-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "homeassist_z2m_tailscale" {
  metadata {
    name      = "homeassist-z2m-tailscale"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.homeassist_z2m_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.homeassist_z2m.metadata[0].name
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
}

resource "random_password" "homeassist_z2m_ui" {
  length  = 32
  special = false
}

resource "vault_kv_secret_v2" "homeassist_z2m_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "homeassist/z2m/config"
  data_json = jsonencode({
    ui_password = random_password.homeassist_z2m_ui.result
  })
}

module "homeassist-z2m-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.homeassist_z2m_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "vault_kv_secret_v2" "homeassist_z2m_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "homeassist/z2m/tls"
  data_json = jsonencode({
    fullchain_pem = module.homeassist-z2m-tls.fullchain_pem
    privkey_pem   = module.homeassist-z2m-tls.privkey_pem
  })
}

resource "vault_kubernetes_auth_backend_role" "homeassist_z2m" {
  backend                          = "kubernetes"
  role_name                        = "homeassist-z2m"
  bound_service_account_names      = ["homeassist-z2m"]
  bound_service_account_namespaces = ["homeassist"]
  token_policies                   = [vault_policy.homeassist.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "homeassist_z2m_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-homeassist-z2m"
      namespace = kubernetes_namespace.homeassist.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "homeassist-z2m-secrets"
          type       = "Opaque"
          data = [
            { objectName = "ui_password", key = "ui_password" },
            { objectName = "z2m_password", key = "z2m_password" },
          ]
        },
        {
          secretName = "homeassist-z2m-tls"
          type       = "kubernetes.io/tls"
          data = [
            { objectName = "tls_crt", key = "tls.crt" },
            { objectName = "tls_key", key = "tls.key" },
          ]
        },
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "homeassist-z2m"
        objects = yamlencode([
          {
            objectName = "ui_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/homeassist/z2m/config"
            secretKey  = "ui_password"
          },
          {
            objectName = "z2m_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/homeassist/mosquitto"
            secretKey  = "z2m_password"
          },
          {
            objectName = "tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/homeassist/z2m/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/homeassist/z2m/tls"
            secretKey  = "privkey_pem"
          },
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.homeassist,
    vault_kubernetes_auth_backend_role.homeassist_z2m,
    vault_kv_secret_v2.homeassist_z2m_config,
    vault_kv_secret_v2.homeassist_z2m_tls,
    vault_kv_secret_v2.homeassist_mosquitto,
    vault_policy.homeassist,
  ]
}
