
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


# Immich provider
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

# Pihole
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

# Registry
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

# Radicale


resource "kubernetes_manifest" "radicale_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-radicale"
      namespace = kubernetes_namespace.radicale.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "radicale-secrets"
          type       = "Opaque"
          data = [
            {
              objectName = "radicale_password"
              key        = "radicale_password"
            }
          ]
        },
        {
          secretName = "radicale-tls"
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
        roleName     = "radicale"
        objects = yamlencode([
          {
            objectName = "radicale_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/radicale/config"
            secretKey  = "radicale_password"
          },
          {
            objectName = "tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/radicale/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/radicale/tls"
            secretKey  = "privkey_pem"
          }
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.radicale,
    vault_kubernetes_auth_backend_role.radicale,
    vault_kv_secret_v2.radicale_config,
    vault_kv_secret_v2.radicale_tls,
    vault_policy.radicale
  ]
}
