resource "kubernetes_deployment" "mcp_duckduckgo" {
  metadata {
    name      = "mcp-duckduckgo"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "mcp-duckduckgo"
      }
    }

    template {
      metadata {
        labels = {
          app = "mcp-duckduckgo"
        }
        annotations = {
          # Rolls the pod whenever the build Job's name changes (i.e. whenever
          # the Dockerfile content hash changes → new image) so `:latest` is
          # actually re-pulled.
          "build-job" = local.mcp_duckduckgo_build_job_name
          # Rolls the pod whenever the nginx config changes.
          "nginx-config-hash" = sha1(kubernetes_config_map.mcp_duckduckgo_nginx_config.data["nginx.conf"])
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
              secret_file = "mcp_duckduckgo_tls_crt"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # DuckDuckGo MCP server (nickclyde/duckduckgo-mcp-server, streamable-http)
        container {
          name              = "mcp-duckduckgo"
          image             = local.mcp_duckduckgo_image
          image_pull_policy = "Always"

          env {
            name  = "FASTMCP_HOST"
            value = "0.0.0.0"
          }
          env {
            name  = "FASTMCP_PORT"
            value = "8000"
          }
          env {
            name  = "DDG_SAFE_SEARCH"
            value = "MODERATE"
          }
          env {
            name  = "DDG_REGION"
            value = "us-en"
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
        }

        # TLS-terminating nginx (exposes /public/mcp-duckduckgo/ on :443)
        container {
          name  = "nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "mcp-duckduckgo-tls"
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

        # Tailscale — routes ALL pod egress through a tailnet exit node
        container {
          name  = "tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "mcp-duckduckgo-tailscale-state"
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
            value = var.mcp_duckduckgo_domain
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

        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.mcp_duckduckgo_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "mcp-duckduckgo-tls"
          secret {
            secret_name = "mcp-duckduckgo-tls"
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.mcp_duckduckgo_secret_provider.manifest.metadata.name
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
      }
    }
  }

  depends_on = [
    kubernetes_manifest.mcp_duckduckgo_secret_provider,
    kubernetes_manifest.mcp_duckduckgo_build,
  ]
}

resource "kubernetes_service" "mcp_duckduckgo" {
  metadata {
    name      = "mcp-duckduckgo"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }
  spec {
    selector = {
      app = "mcp-duckduckgo"
    }
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
  }
}
