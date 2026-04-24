resource "kubernetes_deployment" "mcp_prometheus" {
  metadata {
    name      = "mcp-prometheus"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "mcp-prometheus"
      }
    }

    template {
      metadata {
        labels = {
          app = "mcp-prometheus"
        }
        annotations = {
          "build-job"                           = local.mcp_prometheus_build_job_name
          "secret.reloader.stakater.com/reload" = "mcp-auth,mcp-shared-tls"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.mcp.metadata[0].name

        image_pull_secrets {
          name = kubernetes_secret.mcp_registry_pull_secret.metadata[0].name
        }

        # Pod-level baseline applies to init containers too — no sidecar
        # needing root here (Prom is in-cluster, no tailscale sidecar).
        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          run_as_group    = 1000
          seccomp_profile {
            type = "RuntimeDefault"
          }
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

        # Prometheus MCP server — TLS + routing live in mcp-shared. Prometheus
        # sits in a sibling cluster namespace, so this pod talks HTTP directly
        # over cluster DNS and needs no tailscale sidecar.
        container {
          name              = "mcp-prometheus"
          image             = local.mcp_prometheus_image
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
            name  = "PROMETHEUS_URL"
            value = var.mcp_prometheus_url
          }
          env {
            name  = "LOG_LEVEL"
            value = var.mcp_prometheus_log_level
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
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          # Slower liveness — gives the pod ~90s grace so a slow upstream
          # Prom tick doesn't flap the pod.
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8000
            }
            initial_delay_seconds = 20
            period_seconds        = 30
            failure_threshold     = 3
            timeout_seconds       = 5
          }

          # Pod-level already sets run_as_*/seccomp; this adds the strict
          # container-only knobs.
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
          # Python / httpx / certifi may write here; read_only_root_filesystem
          # would otherwise break them.
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
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
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.mcp_shared_secret_provider,
    kubernetes_manifest.mcp_prometheus_build,
  ]
}

resource "kubernetes_service" "mcp_prometheus" {
  metadata {
    name      = "mcp-prometheus"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }
  spec {
    selector = {
      app = "mcp-prometheus"
    }
    port {
      name        = "http"
      port        = 8000
      target_port = 8000
    }
  }
}
