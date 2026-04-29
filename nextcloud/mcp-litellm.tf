resource "kubernetes_deployment" "mcp_litellm" {
  metadata {
    name      = "mcp-litellm"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "mcp-litellm"
      }
    }

    template {
      metadata {
        labels = {
          app = "mcp-litellm"
        }
        annotations = {
          "build-job"                           = module.mcp_litellm_build.job_name
          "secret.reloader.stakater.com/reload" = "mcp-litellm-secrets"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.mcp.metadata[0].name

        image_pull_secrets {
          name = kubernetes_secret.mcp_registry_pull_secret.metadata[0].name
        }

        # Pin litellm.<hs>.<magic> to the litellm Service ClusterIP so the
        # backend can dial the FQDN (LITELLM_BASE_URL) and keep using the
        # same FQDN-valid TLS cert nginx serves at :443 — no tailnet
        # round-trip needed.
        host_aliases {
          ip        = kubernetes_service.litellm.spec[0].cluster_ip
          hostnames = ["${var.litellm_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"]
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

        init_container {
          name  = "wait-for-litellm-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "mcp_litellm_key_hash_map"
            })
          ]
          volume_mount {
            name       = "litellm-secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # LiteLLM MCP server. TLS + external routing live in mcp-shared;
        # this pod talks to LiteLLM directly via cluster routing.
        container {
          name              = "mcp-litellm"
          image             = local.mcp_litellm_image
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
            name  = "LITELLM_BASE_URL"
            value = "https://${var.litellm_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }
          env {
            name  = "LOG_LEVEL"
            value = var.mcp_litellm_log_level
          }
          env {
            name  = "MCP_UPSTREAM_TIMEOUT"
            value = tostring(var.mcp_litellm_upstream_timeout)
          }
          env {
            name  = "MCP_MAX_LOGS"
            value = tostring(var.mcp_litellm_max_logs)
          }
          env {
            name = "MCP_KEY_HASH_MAP"
            value_from {
              secret_key_ref {
                name = "mcp-litellm-secrets"
                key  = "key_hash_map_json"
              }
            }
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
            name = "LITELLM_MASTER_KEY"
            value_from {
              secret_key_ref {
                name = "mcp-litellm-secrets"
                key  = "master_key"
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

          # Liveness is intentionally slower than readiness: three strikes
          # at 30s spacing = ~90s grace before the pod gets restarted.
          # Prevents flapping if LiteLLM upstream slows down (tool calls
          # stall on the event loop but /healthz is a local route).
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

          security_context {
            run_as_non_root            = true
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

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
          volume_mount {
            name       = "litellm-secrets-store"
            mount_path = "/mnt/secrets-litellm"
            read_only  = true
          }
          # /tmp as emptyDir — Python / httpx / certifi occasionally write
          # here, and read_only_root_filesystem blocks /tmp otherwise.
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
          name = "litellm-secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.mcp_litellm_secret_provider.manifest.metadata.name
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
    kubernetes_manifest.mcp_litellm_secret_provider,
    module.mcp_litellm_build,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "mcp_litellm" {
  metadata {
    name      = "mcp-litellm"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }
  spec {
    selector = {
      app = "mcp-litellm"
    }
    port {
      name        = "http"
      port        = 8000
      target_port = 8000
    }
  }
}
