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
          "build-job" = local.mcp_litellm_build_job_name
        }
      }

      spec {
        service_account_name = kubernetes_service_account.mcp.metadata[0].name

        image_pull_secrets {
          name = kubernetes_secret.mcp_registry_pull_secret.metadata[0].name
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

        # LiteLLM MCP server — TLS + external routing live in mcp-shared.
        # Tailscale sidecar is required because LiteLLM's TLS cert is issued
        # for the tailnet FQDN; talking to litellm.<ns>.svc would fail cert
        # verification (and we want the same auth path production clients
        # use).
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

          # Container-level only: pod-level run_as_non_root would break the
          # tailscale sidecar (needs root + NET_ADMIN).
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

        # Tailscale sidecar — egress-only. Registers on the tailnet so the
        # MCP pod can resolve/reach litellm.<hs>.<magic> with a valid TLS cert.
        container {
          name  = "tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "mcp-litellm-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.mcp_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.mcp_litellm_domain
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
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.mcp_shared_secret_provider,
    kubernetes_manifest.mcp_litellm_secret_provider,
    kubernetes_manifest.mcp_litellm_build,
  ]
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
