resource "random_password" "immich_db_password" {
  length  = 32
  special = false
}

resource "headscale_pre_auth_key" "immich_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.nextcloud_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "immich_tailscale_auth" {
  metadata {
    name      = "immich-tailscale-auth"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.immich_server.key
  }
}

module "immich-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.immich_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "vault_kv_secret_v2" "immich_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "nextcloud/immich"
  data_json = jsonencode({
    db_password = random_password.immich_db_password.result
  })
}

resource "vault_kv_secret_v2" "immich_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "nextcloud/immich-tls"
  data_json = jsonencode({
    fullchain_pem = module.immich-tls.fullchain_pem
    privkey_pem   = module.immich-tls.privkey_pem
  })
}

resource "kubernetes_manifest" "immich_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-immich"
      namespace = kubernetes_namespace.nextcloud.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "immich-secrets"
          type       = "Opaque"
          data = [
            {
              objectName = "immich_db_password"
              key        = "db_password"
            }
          ]
        },
        {
          secretName = "immich-tls"
          type       = "kubernetes.io/tls"
          data = [
            {
              objectName = "immich_tls_crt"
              key        = "tls.crt"
            },
            {
              objectName = "immich_tls_key"
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
            objectName = "immich_db_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/immich"
            secretKey  = "db_password"
          },
          {
            objectName = "immich_tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/immich-tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "immich_tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/immich-tls"
            secretKey  = "privkey_pem"
          }
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.nextcloud,
    vault_kubernetes_auth_backend_role.nextcloud,
    vault_kv_secret_v2.immich_config,
    vault_kv_secret_v2.immich_tls
  ]
}
