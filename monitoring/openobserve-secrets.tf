resource "kubernetes_service_account" "openobserve" {
  metadata {
    name      = "openobserve"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_secret" "openobserve_tailscale_state" {
  metadata {
    name      = "openobserve-tailscale-state"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  type = "Opaque"

  lifecycle {
    ignore_changes = [data, type]
  }
}

resource "kubernetes_role" "openobserve_tailscale" {
  metadata {
    name      = "openobserve-tailscale"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["openobserve-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "openobserve_tailscale" {
  metadata {
    name      = "openobserve-tailscale"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.openobserve_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.openobserve.metadata[0].name
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
}

resource "headscale_pre_auth_key" "openobserve_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.log_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "openobserve_tailscale_auth" {
  metadata {
    name      = "openobserve-tailscale-auth"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.openobserve_server.key
  }
}

module "openobserve-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.openobserve_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "random_password" "openobserve_root" {
  length  = 32
  special = false
}

locals {
  openobserve_root_email    = "admin@${var.headscale_subdomain}.${var.headscale_magic_domain}"
  openobserve_root_password = random_password.openobserve_root.result
  openobserve_basic_b64     = base64encode("${local.openobserve_root_email}:${local.openobserve_root_password}")
  openobserve_fqdn          = "${var.openobserve_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
}

resource "vault_kv_secret_v2" "openobserve_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "openobserve/config"
  data_json = jsonencode({
    root_email    = local.openobserve_root_email
    root_password = local.openobserve_root_password
    basic_b64     = local.openobserve_basic_b64
  })
}

resource "vault_kv_secret_v2" "openobserve_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "openobserve/tls"
  data_json = jsonencode({
    fullchain_pem = module.openobserve-tls.fullchain_pem
    privkey_pem   = module.openobserve-tls.privkey_pem
  })

  # tls-rotator (nextcloud/tls-rotator.tf) owns rotation post-bootstrap.
  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "vault_policy" "openobserve" {
  name = "openobserve-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/openobserve/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "openobserve" {
  backend                          = "kubernetes"
  role_name                        = "openobserve"
  bound_service_account_names      = ["openobserve"]
  bound_service_account_namespaces = ["monitoring"]
  token_policies                   = [vault_policy.openobserve.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "openobserve_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-openobserve"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "openobserve-secrets"
          type       = "Opaque"
          data = [
            { objectName = "root_email", key = "ZO_ROOT_USER_EMAIL" },
            { objectName = "root_password", key = "ZO_ROOT_USER_PASSWORD" },
            { objectName = "basic_b64", key = "OO_AUTH" },
          ]
        },
        {
          secretName = "openobserve-tls"
          type       = "kubernetes.io/tls"
          data = [
            { objectName = "tls_crt", key = "tls.crt" },
            { objectName = "tls_key", key = "tls.key" },
          ]
        },
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "openobserve"
        objects = yamlencode([
          {
            objectName = "root_email"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/openobserve/config"
            secretKey  = "root_email"
          },
          {
            objectName = "root_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/openobserve/config"
            secretKey  = "root_password"
          },
          {
            objectName = "basic_b64"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/openobserve/config"
            secretKey  = "basic_b64"
          },
          {
            objectName = "tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/openobserve/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/openobserve/tls"
            secretKey  = "privkey_pem"
          },
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.monitoring,
    vault_kubernetes_auth_backend_role.openobserve,
    vault_kv_secret_v2.openobserve_config,
    vault_kv_secret_v2.openobserve_tls,
    vault_policy.openobserve,
  ]
}
