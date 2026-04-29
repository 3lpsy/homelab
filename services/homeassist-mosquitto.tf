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
              mosquitto_passwd -c -b /mosquitto/auth/passwd ha "$HA_PASSWORD"
              mosquitto_passwd -b /mosquitto/auth/passwd z2m "$Z2M_PASSWORD"
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
