resource "kubernetes_deployment" "homeassist_z2m" {
  metadata {
    name      = "homeassist-z2m"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "homeassist-z2m" }
    }

    template {
      metadata {
        labels = { app = "homeassist-z2m" }
        annotations = {
          "config-hash"                         = sha1(kubernetes_config_map.homeassist_z2m_config.data["configuration.yaml"])
          "nginx-config-hash"                   = sha1(kubernetes_config_map.homeassist_z2m_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "homeassist-z2m-secrets,homeassist-z2m-tls"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.homeassist_z2m.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "ui_password"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Hashes ui_password into an APR-MD5 htpasswd file mounted into the
        # nginx sidecar. Mirrors radicale's setup-auth init container.
        init_container {
          name  = "setup-auth"
          image = var.image_python
          command = [
            "sh", "-c",
            <<-EOT
              pip install --quiet passlib[bcrypt]
              python -c "
              import os
              from passlib.hash import apr_md5_crypt
              p = os.environ['Z2M_UI_PASSWORD']
              print('${var.homeassist_admin_user}:' + apr_md5_crypt.hash(p))
              " > /etc/nginx-auth/htpasswd
              chmod 644 /etc/nginx-auth/htpasswd
            EOT
          ]

          env {
            name = "Z2M_UI_PASSWORD"
            value_from {
              secret_key_ref {
                name = "homeassist-z2m-secrets"
                key  = "ui_password"
              }
            }
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-auth"
            mount_path = "/etc/nginx-auth"
          }
        }

        # First boot only: seeds configuration.yaml on the PVC. User-owned
        # thereafter (Z2M frontend writes devices / groups / friendly-names
        # here). All TF-managed mqtt.* and serial.* values come in via
        # ZIGBEE2MQTT_CONFIG_* env vars on the main container, so the init
        # never has to touch configuration.yaml after the seed.
        init_container {
          name  = "seed-z2m-config"
          image = var.image_busybox
          command = [
            "sh", "-c",
            <<-EOT
              set -e
              if [ ! -f /app/data/configuration.yaml ]; then
                cp /etc/z2m-config-seed/configuration.yaml /app/data/configuration.yaml
              fi
            EOT
          ]
          volume_mount {
            name       = "z2m-data"
            mount_path = "/app/data"
          }
          volume_mount {
            name       = "z2m-config-seed"
            mount_path = "/etc/z2m-config-seed"
            read_only  = true
          }
        }

        # Zigbee2MQTT
        container {
          name  = "z2m"
          image = var.image_homeassist_z2m

          port {
            container_port = 8080
            name           = "http"
          }

          env {
            name  = "TZ"
            value = var.homeassist_time_zone
          }
          env {
            name  = "ZIGBEE2MQTT_DATA"
            value = "/app/data"
          }
          # ZIGBEE2MQTT_CONFIG_* env vars override the matching keys in
          # configuration.yaml at runtime, never persist to disk, and survive
          # Z2M's schema migrations. Source of truth for all TF-managed
          # broker / serial settings.
          env {
            name  = "ZIGBEE2MQTT_CONFIG_MQTT_SERVER"
            value = "mqtt://mosquitto.homeassist.svc.cluster.local:1883"
          }
          env {
            name  = "ZIGBEE2MQTT_CONFIG_MQTT_USER"
            value = "z2m"
          }
          env {
            name = "ZIGBEE2MQTT_CONFIG_MQTT_PASSWORD"
            value_from {
              secret_key_ref {
                name = "homeassist-z2m-secrets"
                key  = "z2m_password"
              }
            }
          }
          # serial.* envs only when the dongle is actually wired in. Without
          # them Z2M crash-loops with "no coordinator", which is the visible
          # signal that var.homeassist_z2m_usb_device_path is unset.
          dynamic "env" {
            for_each = var.homeassist_z2m_usb_device_path != "" ? [1] : []
            content {
              name  = "ZIGBEE2MQTT_CONFIG_SERIAL_PORT"
              value = "/dev/zigbee"
            }
          }
          dynamic "env" {
            for_each = var.homeassist_z2m_usb_device_path != "" ? [1] : []
            content {
              name  = "ZIGBEE2MQTT_CONFIG_SERIAL_ADAPTER"
              value = "ember"
            }
          }
          # ZBT-2 requires hardware flow control. Z2M defaults serial.rtscts
          # to false and falls back to software flow control (XON/XOFF),
          # which the ZBT-2's EmberZNet firmware does not speak — ASH
          # handshake then fails with HOST_FATAL_ERROR after a few retries.
          # Hard-on it whenever the dongle is wired in.
          dynamic "env" {
            for_each = var.homeassist_z2m_usb_device_path != "" ? [1] : []
            content {
              name  = "ZIGBEE2MQTT_CONFIG_SERIAL_RTSCTS"
              value = "true"
            }
          }
          # ZBT-2's EmberZNet NCP firmware runs at 460800. Z2M's ember
          # adapter defaults to 115200 — mismatch produces an ASH-reset loop
          # at startup even with rtscts on.
          dynamic "env" {
            for_each = var.homeassist_z2m_usb_device_path != "" ? [1] : []
            content {
              name  = "ZIGBEE2MQTT_CONFIG_SERIAL_BAUDRATE"
              value = "460800"
            }
          }

          volume_mount {
            name       = "z2m-data"
            mount_path = "/app/data"
          }
          # secrets-store mount kept so syncSecret keeps homeassist-z2m-secrets
          # populated for the env-var secretKeyRef above and for the nginx
          # sidecar's basic-auth + TLS.
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          # USB coordinator passthrough. Active only when
          # var.homeassist_z2m_usb_device_path is set.
          dynamic "volume_mount" {
            for_each = var.homeassist_z2m_usb_device_path != "" ? [1] : []
            content {
              name       = "zigbee-usb"
              mount_path = "/dev/zigbee"
            }
          }

          # privileged is required for char-device access via hostPath. Gated
          # on the USB var so the pod only escalates when actually needed.
          dynamic "security_context" {
            for_each = var.homeassist_z2m_usb_device_path != "" ? [1] : []
            content {
              privileged = true
            }
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1000m", memory = "1Gi" }
          }

          # Z2M's frontend binds 127.0.0.1:8080 (nginx-sidecar-only). A k8s
          # tcp_socket probe targets the pod IP, not loopback, so it always
          # fails. Exec the check inside the container instead.
          liveness_probe {
            exec {
              command = ["sh", "-c", "nc -z 127.0.0.1 8080"]
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            timeout_seconds       = 10
            failure_threshold     = 5
          }

          readiness_probe {
            exec {
              command = ["sh", "-c", "nc -z 127.0.0.1 8080"]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        # Z2M Volumes
        volume {
          name = "z2m-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.homeassist_z2m_data.metadata[0].name
          }
        }
        volume {
          name = "z2m-config-seed"
          config_map {
            name = kubernetes_config_map.homeassist_z2m_config.metadata[0].name
          }
        }

        dynamic "volume" {
          for_each = var.homeassist_z2m_usb_device_path != "" ? [1] : []
          content {
            name = "zigbee-usb"
            host_path {
              path = var.homeassist_z2m_usb_device_path
              type = "CharDevice"
            }
          }
        }

        # Nginx
        container {
          name  = "homeassist-z2m-nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "homeassist-z2m-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }
          volume_mount {
            name       = "nginx-auth"
            mount_path = "/etc/nginx/htpasswd"
            sub_path   = "htpasswd"
            read_only  = true
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        # Nginx Volumes
        volume {
          name = "homeassist-z2m-tls"
          secret { secret_name = "homeassist-z2m-tls" }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.homeassist_z2m_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "nginx-auth"
          empty_dir {}
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.homeassist_z2m_secret_provider.manifest.metadata.name
            }
          }
        }

        # Tailscale (reuses existing homeassist-tailscale-auth Secret since
        # the pre-auth key is reusable and both pods are owned by the same
        # homeassist tailnet user — they appear as separate devices `homeassist`
        # and `z2m` under that user, both covered by group:homeassist-server
        # ACLs.)
        container {
          name  = "homeassist-z2m-tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "homeassist-z2m-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.homeassist_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.homeassist_z2m_domain
          }
          env {
            name  = "TS_EXTRA_ARGS"
            value = "--login-server=https://${data.terraform_remote_state.homelab.outputs.headscale_server_fqdn}"
          }
          env {
            name  = "TS_TAILSCALED_EXTRA_ARGS"
            value = "--port=41641"
          }

          security_context {
            capabilities {
              add = ["NET_ADMIN"]
            }
          }

          resources {
            requests = {
              cpu    = "20m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }

          volume_mount {
            name       = "dev-net-tun"
            mount_path = "/dev/net/tun"
          }
          volume_mount {
            name       = "tailscale-state"
            mount_path = "/var/lib/tailscale"
          }
        }

        # Tailscale Volumes
        volume {
          name = "dev-net-tun"
          host_path {
            path = "/dev/net/tun"
            type = "CharDevice"
          }
        }
        volume {
          name = "tailscale-state"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.homeassist_z2m_secret_provider,
    kubernetes_deployment.homeassist_mosquitto,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}
