
# SecretProviderClass for Nextcloud secrets from Vault
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
      # Sync secrets to Kubernetes secrets for easy consumption
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
              objectName = "harp_shared_key"
              key        = "harp_shared_key"
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
            objectName = "harp_shared_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/harp"
            secretKey  = "shared_key"
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
    vault_kv_secret_v2.harp,
    vault_kv_secret_v2.collabora_tls
  ]
}
