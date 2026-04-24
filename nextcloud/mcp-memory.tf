resource "kubernetes_deployment" "mcp_memory" {
  metadata {
    name      = "mcp-memory"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "mcp-memory"
      }
    }

    template {
      metadata {
        labels = {
          app = "mcp-memory"
        }
        annotations = {
          "build-job"                           = local.mcp_memory_build_job_name
          "secret.reloader.stakater.com/reload" = "mcp-auth,mcp-shared-tls"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.mcp.metadata[0].name

        image_pull_secrets {
          name = kubernetes_secret.mcp_registry_pull_secret.metadata[0].name
        }

        # fs_group propagates to the PVC mount + CSI secrets-store mount so
        # the non-root mcp user can read/write both. OnRootMismatch skips the
        # recursive chown after the first successful mount.
        security_context {
          run_as_non_root          = true
          run_as_user              = 1000
          run_as_group             = 1000
          fs_group                 = 1000
          fs_group_change_policy   = "OnRootMismatch"
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

        # Memory MCP server — TLS + routing live in the mcp-shared pod.
        container {
          name              = "mcp-memory"
          image             = local.mcp_memory_image
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
            name  = "MCP_DATA_ROOT"
            value = "/data"
          }
          env {
            name  = "LOG_LEVEL"
            value = var.mcp_memory_log_level
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
          env {
            name = "MCP_PATH_SALT"
            value_from {
              secret_key_ref {
                name = "mcp-auth"
                key  = "path_salt"
              }
            }
          }

          port {
            container_port = 8000
            name           = "http"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
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
            name       = "data"
            mount_path = "/data"
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
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.mcp_data.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.mcp_shared_secret_provider,
    kubernetes_manifest.mcp_memory_build,
  ]
}

resource "kubernetes_service" "mcp_memory" {
  metadata {
    name      = "mcp-memory"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }
  spec {
    selector = {
      app = "mcp-memory"
    }
    port {
      name        = "http"
      port        = 8000
      target_port = 8000
    }
  }
}
