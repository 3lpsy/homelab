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
          # Roll the pod when either the upstream mirror, the auth-gate code,
          # or the TOML config changes.
          "build-job"   = local.mcp_k8s_build_job_name
          "auth-build"  = local.mcp_k8s_auth_gate_build_job_name
          "config-hash" = sha1(kubernetes_config_map.mcp_k8s_config.data["config.toml"])
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
          # Upstream image is built FROM ubi9-minimal and runs as 65532; the
          # auth-gate runs as 1000. Set fsGroup so both can read the mounted
          # ConfigMap and downward secrets.
          fs_group = 65532
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

        # Upstream containers/kubernetes-mcp-server. Listens on :8080 inside
        # the pod; the Service exposes only auth-gate's :8000, so 8080 is not
        # reachable from outside the pod.
        container {
          name              = "mcp-k8s"
          image             = local.mcp_k8s_image
          image_pull_policy = "Always"

          # Override the upstream CMD. `--read-only` and `--disable-destructive`
          # are also set in the TOML config; passing them on the CLI as well
          # means an accidental ConfigMap edit can't open up writes — the
          # upstream's flag parser treats CLI as authoritative.
          # Flags per upstream README:
          #   --read-only          : drops every tool annotated readOnlyHint=false
          #   --disable-destructive: drops every tool annotated destructiveHint=true
          args = [
            "--config", "/etc/mcp/config.toml",
            "--read-only",
            "--disable-destructive",
          ]

          security_context {
            run_as_user                = 65532
            run_as_group               = 65532
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

          # Upstream binary has no HTTP `/healthz`; TCP readiness is the
          # best we can do. Matching liveness restarts the pod if the Go
          # server's listen socket wedges.
          readiness_probe {
            tcp_socket {
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          liveness_probe {
            tcp_socket {
              port = 8080
            }
            initial_delay_seconds = 20
            period_seconds        = 30
            failure_threshold     = 3
            timeout_seconds       = 5
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/mcp"
            read_only  = true
          }
          # Upstream binary writes nothing under /tmp normally; mount tmpfs in
          # case it ever does, so read_only_root_filesystem stays on.
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }

        # Auth gate — same pod, validates Bearer against MCP_API_KEYS and
        # reverse-proxies to the upstream over loopback. This is the only
        # container exposed via the Service.
        container {
          name              = "auth-gate"
          image             = local.mcp_k8s_auth_gate_image
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
            name  = "UPSTREAM_URL"
            value = "http://127.0.0.1:8080"
          }
          env {
            name  = "LOG_LEVEL"
            value = var.mcp_k8s_log_level
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
              cpu    = "25m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "256Mi"
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
          # Slower liveness — ~90s grace so a stalled upstream doesn't flap
          # the pod.
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
          # /tmp emptyDir for Python / httpx / certifi temp files; required
          # because read_only_root_filesystem is on.
          volume_mount {
            name       = "auth-gate-tmp"
            mount_path = "/tmp"
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.mcp_k8s_config.metadata[0].name
          }
        }
        volume {
          name = "tmp"
          empty_dir {}
        }
        volume {
          name = "auth-gate-tmp"
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
    kubernetes_manifest.mcp_k8s_build,
    kubernetes_manifest.mcp_k8s_auth_gate_build,
  ]
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
    # Only the auth-gate port is exposed; upstream :8080 stays pod-internal.
    port {
      name        = "http"
      port        = 8000
      target_port = 8000
    }
  }
}
