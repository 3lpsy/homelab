resource "kubernetes_deployment" "litellm_postgres" {
  metadata {
    name      = "litellm-postgres"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "litellm-postgres"
      }
    }

    template {
      metadata {
        labels = {
          app = "litellm-postgres"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.litellm.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "litellm_db_password"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        container {
          name  = "postgres"
          image = var.image_litellm_postgres

          env {
            name  = "POSTGRES_DB"
            value = "litellm"
          }
          env {
            name  = "POSTGRES_USER"
            value = "litellm"
          }
          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = "litellm-secrets"
                key  = "db_password"
              }
            }
          }

          port {
            container_port = 5432
          }

          volume_mount {
            name       = "litellm-postgres-data"
            mount_path = "/var/lib/postgresql/data"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          liveness_probe {
            exec {
              command = ["pg_isready", "-U", "litellm", "-d", "litellm"]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          readiness_probe {
            exec {
              command = ["pg_isready", "-U", "litellm", "-d", "litellm"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }

        volume {
          name = "litellm-postgres-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.litellm_postgres_data.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.litellm_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.litellm_secret_provider
  ]
}

resource "kubernetes_service" "litellm_postgres" {
  metadata {
    name      = "litellm-postgres"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }
  spec {
    selector = {
      app = "litellm-postgres"
    }
    port {
      port        = 5432
      target_port = 5432
    }
  }
}

resource "kubernetes_deployment" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "litellm"
      }
    }

    template {
      metadata {
        labels = {
          app = "litellm"
        }
        annotations = {
          "config-hash"       = sha1(kubernetes_config_map.litellm_config.data["config.yaml"])
          "nginx-config-hash" = sha1(kubernetes_config_map.litellm_nginx_config.data["nginx.conf"])
        }
      }

      spec {
        service_account_name = kubernetes_service_account.litellm.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "litellm_master_key"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # LiteLLM Proxy
        container {
          name  = "litellm"
          image = var.image_litellm
          # :main-latest moves — force fresh pull so Prisma migrations run
          # against the newest schema on each rollout. Fixes the recurring
          # `column LiteLLM_MCPServerTable.source_url does not exist` log
          # dumps from the old in-cluster schema.
          image_pull_policy = "Always"

          args = ["--config", "/etc/litellm/config.yaml", "--port", "4000"]

          port {
            container_port = 4000
            name           = "http"
          }

          env {
            name = "LITELLM_MASTER_KEY"
            value_from {
              secret_key_ref {
                name = "litellm-secrets"
                key  = "master_key"
              }
            }
          }

          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = "litellm-secrets"
                key  = "database_url"
              }
            }
          }

          env {
            name = "AWS_ACCESS_KEY_ID"
            value_from {
              secret_key_ref {
                name = "litellm-secrets"
                key  = "aws_access_key_id"
              }
            }
          }

          env {
            name = "AWS_SECRET_ACCESS_KEY"
            value_from {
              secret_key_ref {
                name = "litellm-secrets"
                key  = "aws_secret_access_key"
              }
            }
          }

          env {
            name  = "AWS_DEFAULT_REGION"
            value = var.aws_region
          }

          env {
            name = "DEEPINFRA_API_KEY"
            value_from {
              secret_key_ref {
                name = "litellm-secrets"
                key  = "deepinfra_api_key"
              }
            }
          }

          volume_mount {
            name       = "litellm-config"
            mount_path = "/etc/litellm/config.yaml"
            sub_path   = "config.yaml"
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "1Gi"
            }
            limits = {
              cpu    = "500m"
              memory = "2Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health/liveliness"
              port = 4000
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 10
          }

          readiness_probe {
            http_get {
              path = "/health/readiness"
              port = 4000
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        # Nginx
        container {
          name  = "litellm-nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "litellm-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }
        }

        # Tailscale
        container {
          name  = "litellm-tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "litellm-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.litellm_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.litellm_domain
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

        # Volumes
        volume {
          name = "litellm-config"
          config_map {
            name = kubernetes_config_map.litellm_config.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.litellm_secret_provider.manifest.metadata.name
            }
          }
        }
        volume {
          name = "litellm-tls"
          secret {
            secret_name = "litellm-tls"
          }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.litellm_nginx_config.metadata[0].name
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

  depends_on = [
    kubernetes_manifest.litellm_secret_provider,
    kubernetes_deployment.litellm_postgres,
  ]
}

resource "kubernetes_service" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }
  spec {
    selector = {
      app = "litellm"
    }
    port {
      port        = 4000
      target_port = 4000
    }
  }
}
