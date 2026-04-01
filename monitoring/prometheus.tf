resource "kubernetes_deployment" "prometheus" {
  metadata {
    name      = "prometheus"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = { app = "prometheus" }
    }

    template {
      metadata {
        labels = { app = "prometheus" }
      }

      spec {
        service_account_name = kubernetes_service_account.prometheus.metadata[0].name

        init_container {
          name  = "fix-permissions"
          image = var.image_busybox
          command = [
            "sh", "-c",
            "chown -R 65534:65534 /prometheus"
          ]
          volume_mount {
            name       = "prometheus-data"
            mount_path = "/prometheus"
          }
        }

        container {
          name  = "prometheus"
          image = var.image_prometheus

          args = [
            "--config.file=/etc/prometheus/prometheus.yml",
            "--storage.tsdb.path=/prometheus",
            "--storage.tsdb.retention.time=${var.prometheus_retention}",
            "--web.enable-lifecycle",
          ]

          port {
            container_port = 9090
            name           = "http"
          }

          volume_mount {
            name       = "prometheus-config"
            mount_path = "/etc/prometheus"
          }
          volume_mount {
            name       = "prometheus-data"
            mount_path = "/prometheus"
          }

          resources {
            requests = { cpu = "250m", memory = "512Mi" }
            limits   = { cpu = "1000m", memory = "2Gi" }
          }

          liveness_probe {
            http_get {
              path = "/-/healthy"
              port = 9090
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/-/ready"
              port = 9090
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        volume {
          name = "prometheus-config"
          config_map {
            name = kubernetes_config_map.prometheus_config.metadata[0].name
          }
        }
        volume {
          name = "prometheus-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.prometheus_data.metadata[0].name
          }
        }

        container {
          name  = "alertmanager"
          image = var.image_alertmanager

          args = [
            "--config.file=/etc/alertmanager/alertmanager.yml",
            "--storage.path=/alertmanager",
          ]

          port {
            container_port = 9093
            name           = "alertmanager"
          }

          volume_mount {
            name       = "alertmanager-config"
            mount_path = "/etc/alertmanager"
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "250m", memory = "256Mi" }
          }

          liveness_probe {
            http_get {
              path = "/-/healthy"
              port = 9093
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/-/ready"
              port = 9093
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }

        volume {
          name = "alertmanager-config"
          config_map {
            name = kubernetes_config_map.alertmanager_config.metadata[0].name
          }
        }

        container {
          name  = "ntfy-bridge"
          image = var.image_python

          command = [
            "python3", "/app/ntfy-bridge.py",
            "--ntfy-url", "https://${var.ntfy_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}",
            "--ntfy-topic", var.ntfy_alert_topic,
            "--port", "8085",
          ]

          port {
            container_port = 8085
            name           = "ntfy-bridge"
          }

          volume_mount {
            name       = "ntfy-bridge-script"
            mount_path = "/app"
            read_only  = true
          }

          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "100m", memory = "64Mi" }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8085
            }
            initial_delay_seconds = 5
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8085
            }
            initial_delay_seconds = 2
            period_seconds        = 10
          }
        }

        volume {
          name = "ntfy-bridge-script"
          config_map {
            name = kubernetes_config_map.ntfy_bridge_script.metadata[0].name
          }
        }

        container {
          name  = "tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "prometheus-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.prometheus_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = "prometheus"
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

          volume_mount {
            name       = "dev-net-tun"
            mount_path = "/dev/net/tun"
          }
          volume_mount {
            name       = "tailscale-state"
            mount_path = "/var/lib/tailscale"
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "192Mi" }
          }
        }

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
}

resource "kubernetes_service" "prometheus" {
  metadata {
    name      = "prometheus"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    selector = { app = "prometheus" }

    port {
      name        = "http"
      port        = 9090
      target_port = 9090
    }
  }
}
