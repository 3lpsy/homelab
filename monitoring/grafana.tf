resource "kubernetes_config_map" "grafana_datasources" {
  metadata {
    name      = "grafana-datasources"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "datasources.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name      = "Prometheus"
        type      = "prometheus"
        url       = "http://prometheus:9090"
        access    = "proxy"
        isDefault = true
      }]
    })
  }
}

resource "kubernetes_config_map" "grafana_dashboard_provisioning" {
  metadata {
    name      = "grafana-dashboard-provisioning"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "dashboards.yaml" = yamlencode({
      apiVersion = 1
      providers = [{
        name            = "default"
        orgId           = 1
        folder          = ""
        type            = "file"
        disableDeletion = false
        editable        = true
        options = {
          path = "/var/lib/grafana/dashboards"
        }
      }]
    })
  }
}

resource "kubernetes_config_map" "grafana_nginx_config" {
  metadata {
    name      = "grafana-nginx-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "nginx.conf" = <<-EOT
      events {
        worker_connections 1024;
      }
      http {
        upstream grafana {
          server localhost:3000;
        }

        map $http_upgrade $connection_upgrade {
          default upgrade;
          '' close;
        }

        server {
          listen 443 ssl;
          server_name ${var.grafana_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain};

          ssl_certificate     /etc/nginx/certs/tls.crt;
          ssl_certificate_key /etc/nginx/certs/tls.key;
          ssl_protocols       TLSv1.2 TLSv1.3;
          ssl_ciphers         HIGH:!aNULL:!MD5;
          ssl_prefer_server_ciphers on;

          add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

          location / {
            proxy_pass http://grafana;
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
          }

          # Grafana Live WebSocket support
          location /api/live/ {
            proxy_pass http://grafana;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host $http_host;
          }
        }
      }
    EOT
  }
}

resource "kubernetes_persistent_volume_claim" "grafana_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "grafana-data"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.grafana_storage_size
      }
    }
  }
  wait_until_bound = false
}

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
      }

      spec {
        service_account_name = kubernetes_service_account.grafana.metadata[0].name

        # Wait for Vault CSI secrets
        init_container {
          name  = "wait-for-secrets"
          image = "busybox:latest"
          command = [
            "sh", "-c",
            <<-EOT
              echo 'Waiting for Grafana secrets to sync from Vault...'
              TIMEOUT=300
              ELAPSED=0
              until [ -f /mnt/secrets/admin_password ]; do
                if [ $ELAPSED -ge $TIMEOUT ]; then
                  echo "Timeout waiting for secrets after $${TIMEOUT}s"
                  exit 1
                fi
                echo "Still waiting... ($${ELAPSED}s)"
                sleep 5
                ELAPSED=$((ELAPSED + 5))
              done
              echo 'Grafana secrets synced successfully!'
            EOT
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
          image = "busybox:latest"
          command = [
            "sh", "-c",
            "chown -R 472:472 /var/lib/grafana"
          ]
          volume_mount {
            name       = "grafana-data"
            mount_path = "/var/lib/grafana"
          }
        }

        container {
          name  = "tailscale"
          image = "tailscale/tailscale:latest"

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
        }

        container {
          name  = "nginx"
          image = "nginx:alpine"

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

        container {
          name  = "grafana"
          image = "grafana/grafana:latest"

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
      }
    }
  }

  depends_on = [
    kubernetes_manifest.grafana_secret_provider,
    kubernetes_deployment.prometheus
  ]
}

resource "kubernetes_service" "grafana_internal" {
  metadata {
    name      = "grafana-internal"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  spec {
    selector = { app = "grafana" }
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
    type = "ClusterIP"
  }
}
