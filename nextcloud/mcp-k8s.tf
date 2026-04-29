resource "kubernetes_deployment" "mcp_k8s" {
  metadata {
    name      = "mcp-k8s"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "mcp-k8s"
      }
    }

    template {
      metadata {
        labels = {
          app = "mcp-k8s"
        }
        annotations = {
          # Roll the pod whenever the image rebuilds. No ConfigMap to hash —
          # all config travels as env vars below.
          "build-job"                           = module.mcp_k8s_build.job_name
          "secret.reloader.stakater.com/reload" = "mcp-auth,mcp-shared-tls"
        }
      }

      spec {
        # Dedicated SA — see mcp-k8s-rbac.tf. The shared `mcp` SA carries
        # tailscale-state RBAC unrelated to k8s API access.
        service_account_name = kubernetes_service_account.mcp_k8s.metadata[0].name

        image_pull_secrets {
          name = kubernetes_secret.mcp_registry_pull_secret.metadata[0].name
        }

        security_context {
          run_as_non_root = true
          fs_group        = 1000
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
          security_context {
            run_as_user  = 1000
            run_as_group = 1000
          }
        }

        # Single container — Python MCP server speaking streamable-http on
        # 8000 with built-in bearer-token auth. Talks to the K8s API via the
        # in-cluster ServiceAccount token (RBAC in mcp-k8s-rbac.tf).
        container {
          name              = "mcp-k8s"
          image             = local.mcp_k8s_image
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
            name  = "LOG_LEVEL"
            value = var.mcp_k8s_log_level
          }
          # Allowlisted namespaces — the server refuses requests for any
          # other namespace before issuing the K8s call (cheap ToolError,
          # avoids leaking namespace existence). RBAC is the cluster-side
          # gate; this is the application-side gate.
          env {
            name  = "MCP_K8S_ALLOWED_NAMESPACES"
            value = join(",", var.mcp_k8s_allowed_namespaces)
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

          security_context {
            run_as_user                = 1000
            run_as_group               = 1000
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
            seccomp_profile {
              type = "RuntimeDefault"
            }
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

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
          # /tmp emptyDir for Python / certifi temp files; required because
          # read_only_root_filesystem is on.
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }

        volume {
          name = "tmp"
          empty_dir {}
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
    module.mcp_k8s_build,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "mcp_k8s" {
  metadata {
    name      = "mcp-k8s"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }
  spec {
    selector = {
      app = "mcp-k8s"
    }
    port {
      name        = "http"
      port        = 8000
      target_port = 8000
    }
  }
}
