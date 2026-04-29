resource "kubernetes_deployment" "grafana" {
  metadata {
    name      = "grafana"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "grafana" }
    }

    template {
      metadata {
        labels = { app = "grafana" }
        annotations = {
          "datasources-hash"                    = sha1(kubernetes_config_map.grafana_datasources.data["datasources.yaml"])
          "dashboards-hash"                     = sha1(kubernetes_config_map.grafana_dashboard_provisioning.data["dashboards.yaml"])
          "nginx-config-hash"                   = sha1(kubernetes_config_map.grafana_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "grafana-secrets,grafana-tls"
          # Dashboards + datasources are provisioned by monitoring-conf via
          # the Grafana provider; only Grafana's session/user state lives in
          # this PVC. Lost on restore = users re-login, no real loss.
          "backup.velero.io/backup-volumes-excludes" = "grafana-data"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.grafana.metadata[0].name

        # Wait for Vault CSI secrets
        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "admin_password"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Fix Grafana data dir ownership (grafana runs as UID 472)
        init_container {
          name  = "fix-permissions"
          image = var.image_busybox
          command = [
            "sh", "-c",
            "chown -R 472:472 /var/lib/grafana"
          ]
          volume_mount {
            name       = "grafana-data"
            mount_path = "/var/lib/grafana"
          }
        }

        # Grafana
        container {
          name  = "grafana"
          image = var.image_grafana

          port {
            container_port = 3000
            name           = "http"
          }

          env {
            name  = "GF_SERVER_HTTP_PORT"
            value = "3000"
          }
          env {
            name  = "GF_SERVER_ROOT_URL"
            value = "https://${var.grafana_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }
          env {
            name  = "GF_SECURITY_ADMIN_USER"
            value = var.grafana_admin_user
          }
          env {
            name = "GF_SECURITY_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = "grafana-secrets"
                key  = "admin_password"
              }
            }
          }
          env {
            name  = "GF_USERS_ALLOW_SIGN_UP"
            value = "false"
          }

          volume_mount {
            name       = "grafana-data"
            mount_path = "/var/lib/grafana"
          }
          # Empty dir at the path the `file` dashboard provider polls every
          # 30s. Without this, grafana spams `Cannot read directory` ERRORs.
          # Actual dashboards are provisioned via API by the monitoring-conf
          # deployment, not through this path.
          volume_mount {
            name       = "grafana-dashboards-empty"
            mount_path = "/var/lib/grafana/dashboards"
          }
          volume_mount {
            name       = "grafana-datasources"
            mount_path = "/etc/grafana/provisioning/datasources"
          }
          volume_mount {
            name       = "grafana-dashboard-provisioning"
            mount_path = "/etc/grafana/provisioning/dashboards"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }

          liveness_probe {
            http_get {
              path = "/api/health"
              port = 3000
            }
            initial_delay_seconds = 60
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/api/health"
              port = 3000
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }
        # Grafana Volumes
        volume {
          name = "grafana-datasources"
          config_map {
            name = kubernetes_config_map.grafana_datasources.metadata[0].name
          }
        }
        volume {
          name = "grafana-dashboard-provisioning"
          config_map {
            name = kubernetes_config_map.grafana_dashboard_provisioning.metadata[0].name
          }
        }
        volume {
          name = "grafana-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.grafana_data.metadata[0].name
          }
        }
        volume {
          name = "grafana-dashboards-empty"
          empty_dir {}
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.grafana_secret_provider.manifest.metadata.name
            }
          }
        }

        # Nginx
        container {
          name  = "nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "grafana-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }
        # Nginx Volumes
        volume {
          name = "grafana-tls"
          secret { secret_name = "grafana-tls" }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.grafana_nginx_config.metadata[0].name
          }
        }

        # Tailscale
        container {
          name  = "tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "grafana-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.grafana_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.grafana_domain
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
    kubernetes_manifest.grafana_secret_provider,
    kubernetes_deployment.prometheus
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}
