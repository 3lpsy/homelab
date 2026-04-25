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

        # Seeds Z2M's configuration.yaml on the PVC the first time only,
        # then always writes secrets.yaml from the CSI-mounted MQTT password
        # so Vault rotation flows through and Z2M's `!secret mqtt_password`
        # reference resolves at startup.
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
              PASSWORD=$(cat /mnt/secrets/z2m_password)
              printf 'mqtt_password: "%s"\n' "$PASSWORD" > /app/data/secrets.yaml
              chmod 600 /app/data/secrets.yaml
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
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
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

          volume_mount {
            name       = "z2m-data"
            mount_path = "/app/data"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          # USB coordinator passthrough. Active only when
          # var.homeassist_z2m_usb_device_path is set — until then the dynamic
          # block is empty and Z2M will crash-loop with "no serial port",
          # which is the visible signal that the dongle is not yet wired in.
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

          liveness_probe {
            tcp_socket {
              port = 8080
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            timeout_seconds       = 10
            failure_threshold     = 5
          }

          readiness_probe {
            tcp_socket {
              port = 8080
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
