resource "kubernetes_deployment" "mcp_searxng" {
  metadata {
    name      = "mcp-searxng"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "mcp-searxng"
      }
    }

    template {
      metadata {
        labels = {
          app = "mcp-searxng"
        }
        annotations = {
          "build-job" = local.mcp_searxng_build_job_name
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

        # SearXNG MCP server — TLS + external routing live in mcp-shared.
        # Tailscale sidecar is retained because this pod needs outbound
        # tailnet access to reach searxng.<hs>.<magic> for upstream calls
        # (the cert would TLS-fail on an in-cluster DNS hop).
        container {
          name              = "mcp-searxng"
          image             = local.mcp_searxng_image
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
            name  = "MCP_SEARXNG_URL"
            value = "https://${var.searxng_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }
          env {
            name  = "LOG_LEVEL"
            value = var.mcp_searxng_log_level
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
          # Slower liveness — ~90s grace so a slow upstream SearXNG or
          # tailnet blip doesn't flap the pod.
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
          # /tmp emptyDir for Python / httpx / certifi temp writes; required
          # because read_only_root_filesystem is on.
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }

        # Tailscale sidecar — egress-only (no TS_HOSTNAME is still advertised
        # to Headscale, but no traffic is destined to this node).
        container {
          name  = "tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "mcp-searxng-tailscale-state"
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
            value = var.mcp_searxng_domain
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
    kubernetes_manifest.mcp_searxng_build,
  ]
}

resource "kubernetes_service" "mcp_searxng" {
  metadata {
    name      = "mcp-searxng"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }
  spec {
    selector = {
      app = "mcp-searxng"
    }
    port {
      name        = "http"
      port        = 8000
      target_port = 8000
    }
  }
}
