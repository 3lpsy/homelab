resource "kubernetes_deployment" "mcp_time" {
  metadata {
    name      = "mcp-time"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "mcp-time"
      }
    }

    template {
      metadata {
        labels = {
          app = "mcp-time"
        }
        annotations = {
          "build-job"                           = local.mcp_time_build_job_name
          "secret.reloader.stakater.com/reload" = "mcp-auth,mcp-shared-tls"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.mcp.metadata[0].name

        image_pull_secrets {
          name = kubernetes_secret.mcp_registry_pull_secret.metadata[0].name
        }

        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          run_as_group    = 1000
        }

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "mcp_shared_api_keys_csv"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Time MCP server — TLS + routing live in mcp-shared. No upstream, no
        # tenant state, so no tailscale sidecar and no PVC.
        container {
          name              = "mcp-time"
          image             = local.mcp_time_image
          image_pull_policy = "Always"

          env {
            name  = "MCP_HOST"
            value = "0.0.0.0"
          }
          env {
            name  = "MCP_PORT"
            value = "8000"
          }
          env {
            name  = "MCP_DEFAULT_TIMEZONE"
            value = var.mcp_time_default_timezone
          }
          env {
            name  = "LOG_LEVEL"
            value = var.mcp_time_log_level
          }
          env {
            name = "MCP_API_KEYS"
            value_from {
              secret_key_ref {
                name = "mcp-auth"
                key  = "api_keys_csv"
              }
            }
          }

          port {
            container_port = 8000
            name           = "http"
          }

          resources {
            requests = {
              cpu    = "25m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "256Mi"
            }
          }

          readiness_probe {
            tcp_socket {
              port = 8000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.mcp_shared_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.mcp_shared_secret_provider,
    kubernetes_manifest.mcp_time_build,
  ]
}

resource "kubernetes_service" "mcp_time" {
  metadata {
    name      = "mcp-time"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }
  spec {
    selector = {
      app = "mcp-time"
    }
    port {
      name        = "http"
      port        = 8000
      target_port = 8000
    }
  }
}
