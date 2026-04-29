resource "kubernetes_service_account" "homeassist_mosquitto" {
  metadata {
    name      = "homeassist-mosquitto"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  automount_service_account_token = false
}

resource "random_password" "homeassist_mqtt_ha" {
  length  = 32
  special = false
}

resource "random_password" "homeassist_mqtt_z2m" {
  length  = 32
  special = false
}

resource "vault_kv_secret_v2" "homeassist_mosquitto" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "homeassist/mosquitto"
  data_json = jsonencode({
    ha_password  = random_password.homeassist_mqtt_ha.result
    z2m_password = random_password.homeassist_mqtt_z2m.result
  })
}

resource "vault_kubernetes_auth_backend_role" "homeassist_mosquitto" {
  backend                          = "kubernetes"
  role_name                        = "homeassist-mosquitto"
  bound_service_account_names      = ["homeassist-mosquitto"]
  bound_service_account_namespaces = ["homeassist"]
  token_policies                   = [vault_policy.homeassist.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "homeassist_mosquitto_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-homeassist-mosquitto"
      namespace = kubernetes_namespace.homeassist.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "homeassist-mosquitto-secrets"
          type       = "Opaque"
          data = [
            { objectName = "ha_password", key = "ha_password" },
            { objectName = "z2m_password", key = "z2m_password" },
          ]
        }
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "homeassist-mosquitto"
        objects = yamlencode([
          {
            objectName = "ha_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/homeassist/mosquitto"
            secretKey  = "ha_password"
          },
          {
            objectName = "z2m_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/homeassist/mosquitto"
            secretKey  = "z2m_password"
          },
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.homeassist,
    vault_kubernetes_auth_backend_role.homeassist_mosquitto,
    vault_kv_secret_v2.homeassist_mosquitto,
    vault_policy.homeassist,
  ]
}
