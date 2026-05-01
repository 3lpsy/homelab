# MQTT broker for Home Assistant + zigbee2mqtt. Internal-only — no TLS,
# no nginx sidecar, no tailscale ingress (port 1883 cluster-local). The
# plumbing modules don't apply here, so secrets/config/pvc/deployment all
# stay hand-rolled.
#
# Auth: bcrypt-hashed password file built fresh on every pod start by the
# build-passwd init container from CSI-synced ha_password + z2m_password
# (sourced from `homeassist/mosquitto` Vault path).

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

# Frigate publishes detection events here. Cross-ns: pod lives in the
# `frigate` namespace, broker lives in `homeassist`. NetworkPolicy in
# services/frigate-network.tf permits the 1883 hop.
resource "random_password" "homeassist_mqtt_frigate" {
  length  = 32
  special = false
}

resource "vault_kv_secret_v2" "homeassist_mosquitto" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "homeassist/mosquitto"
  data_json = jsonencode({
    ha_password      = random_password.homeassist_mqtt_ha.result
    z2m_password     = random_password.homeassist_mqtt_z2m.result
    frigate_password = random_password.homeassist_mqtt_frigate.result
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
            { objectName = "frigate_password", key = "frigate_password" },
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
          {
            objectName = "frigate_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/homeassist/mosquitto"
            secretKey  = "frigate_password"
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

resource "kubernetes_persistent_volume_claim" "homeassist_mosquitto_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "homeassist-mosquitto-data"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_config_map" "homeassist_mosquitto_config" {
  metadata {
    name      = "homeassist-mosquitto-config"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  data = {
    "mosquitto.conf" = <<-EOT
      persistence true
      persistence_location /mosquitto/data/
      log_dest stdout
      log_type error
      log_type warning
      log_type notice

      listener 1883
      protocol mqtt
      allow_anonymous false
      password_file /mosquitto/auth/passwd
    EOT
  }
}

resource "kubernetes_deployment" "homeassist_mosquitto" {
  metadata {
    name      = "homeassist-mosquitto"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "homeassist-mosquitto" }
    }

    template {
      metadata {
        labels = { app = "homeassist-mosquitto" }
        annotations = {
          "config-hash"                         = sha1(kubernetes_config_map.homeassist_mosquitto_config.data["mosquitto.conf"])
          "secret.reloader.stakater.com/reload" = "homeassist-mosquitto-secrets"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.homeassist_mosquitto.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "ha_password"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Generates /mosquitto/auth/passwd with bcrypt-hashed entries for the
        # `ha` and `z2m` users from the plaintext passwords synced via CSI.
        # Re-runs on every pod start so a Vault rotation flows through.
        init_container {
          name  = "build-passwd"
          image = var.image_homeassist_mosquitto
          command = [
            "sh", "-c",
            <<-EOT
              set -e
              HA_PASSWORD=$(cat /mnt/secrets/ha_password)
              Z2M_PASSWORD=$(cat /mnt/secrets/z2m_password)
              FRIGATE_PASSWORD=$(cat /mnt/secrets/frigate_password)
              mosquitto_passwd -c -b /mosquitto/auth/passwd ha "$HA_PASSWORD"
              mosquitto_passwd -b /mosquitto/auth/passwd z2m "$Z2M_PASSWORD"
              mosquitto_passwd -b /mosquitto/auth/passwd frigate "$FRIGATE_PASSWORD"
              # Init runs as root; main mosquitto container runs as UID 1883.
              # Without chown, mosquitto can't read its own password file.
              chown 1883:1883 /mosquitto/auth/passwd
              chmod 640 /mosquitto/auth/passwd
            EOT
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
          volume_mount {
            name       = "mosquitto-auth"
            mount_path = "/mosquitto/auth"
          }
        }

        container {
          name  = "mosquitto"
          image = var.image_homeassist_mosquitto

          args = ["mosquitto", "-c", "/mosquitto/config/mosquitto.conf"]

          port {
            container_port = 1883
            name           = "mqtt"
          }

          volume_mount {
            name       = "mosquitto-data"
            mount_path = "/mosquitto/data"
          }
          volume_mount {
            name       = "mosquitto-config-vol"
            mount_path = "/mosquitto/config/mosquitto.conf"
            sub_path   = "mosquitto.conf"
          }
          volume_mount {
            name       = "mosquitto-auth"
            mount_path = "/mosquitto/auth"
            read_only  = true
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "20m", memory = "32Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }

          liveness_probe {
            tcp_socket {
              port = 1883
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }

          readiness_probe {
            tcp_socket {
              port = 1883
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }

        volume {
          name = "mosquitto-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.homeassist_mosquitto_data.metadata[0].name
          }
        }
        volume {
          name = "mosquitto-config-vol"
          config_map {
            name = kubernetes_config_map.homeassist_mosquitto_config.metadata[0].name
          }
        }
        volume {
          name = "mosquitto-auth"
          empty_dir {}
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.homeassist_mosquitto_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.homeassist_mosquitto_secret_provider
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "homeassist_mosquitto" {
  metadata {
    name      = "mosquitto"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }

  spec {
    type     = "ClusterIP"
    selector = { app = "homeassist-mosquitto" }

    port {
      name        = "mqtt"
      port        = 1883
      target_port = 1883
      protocol    = "TCP"
    }
  }
}
