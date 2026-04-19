resource "kubernetes_deployment" "thunderbolt_backend" {
  metadata {
    name      = "thunderbolt-backend"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "thunderbolt-backend"
      }
    }

    template {
      metadata {
        labels = {
          app = "thunderbolt-backend"
        }
        annotations = {
          # Rolls the pod whenever the backend build Job's name changes.
          "build-job" = local.thunderbolt_backend_build_job_name
        }
      }

      spec {
        service_account_name = kubernetes_service_account.thunderbolt.metadata[0].name

        image_pull_secrets {
          name = kubernetes_secret.thunderbolt_registry_pull_secret.metadata[0].name
        }

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "thunderbolt_better_auth_secret"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        container {
          name  = "backend"
          image = local.thunderbolt_backend_image

          env {
            name  = "NODE_ENV"
            value = "production"
          }
          env {
            name  = "LOG_LEVEL"
            value = "INFO"
          }
          env {
            name  = "PORT"
            value = "8000"
          }

          # Auth
          env {
            name  = "AUTH_MODE"
            value = "oidc"
          }
          env {
            name  = "WAITLIST_ENABLED"
            value = "false"
          }
          env {
            name  = "OIDC_ISSUER"
            value = "${local.thunderbolt_public_url}/realms/thunderbolt"
          }
          env {
            name  = "OIDC_CLIENT_ID"
            value = "thunderbolt-app"
          }
          env {
            name = "OIDC_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = "thunderbolt-secrets"
                key  = "oidc_client_secret"
              }
            }
          }
          env {
            name = "BETTER_AUTH_SECRET"
            value_from {
              secret_key_ref {
                name = "thunderbolt-secrets"
                key  = "better_auth_secret"
              }
            }
          }
          env {
            name  = "BETTER_AUTH_URL"
            value = local.thunderbolt_public_url
          }
          env {
            name  = "APP_URL"
            value = local.thunderbolt_public_url
          }
          env {
            name  = "TRUSTED_ORIGINS"
            value = local.thunderbolt_public_url
          }
          env {
            name  = "CORS_ORIGINS"
            value = "${local.thunderbolt_public_url},tauri://localhost,http://tauri.localhost"
          }

          # Database
          env {
            name = "DATABASE_DRIVER"
            value = "postgres"
          }
          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = "thunderbolt-secrets"
                key  = "database_url"
              }
            }
          }

          # PowerSync
          # This value is returned verbatim from GET /v1/powersync/token to
          # the browser as `powerSyncUrl`, so it must be reachable from the
          # browser — not the cluster-internal service name. Route through
          # the nginx sidecar's /powersync/ location, which strips the
          # prefix before forwarding to thunderbolt-powersync:8080.
          env {
            name  = "POWERSYNC_URL"
            value = "${local.thunderbolt_public_url}/powersync"
          }
          env {
            name = "POWERSYNC_JWT_SECRET"
            value_from {
              secret_key_ref {
                name = "thunderbolt-secrets"
                key  = "powersync_jwt_secret"
              }
            }
          }
          env {
            name  = "POWERSYNC_JWT_KID"
            value = "thunderbolt-powersync"
          }
          env {
            name  = "POWERSYNC_TOKEN_EXPIRY_SECONDS"
            value = "3600"
          }

          # Rate limiting / misc
          env {
            name  = "RATE_LIMIT_ENABLED"
            value = "false"
          }

          # Pro mode search/fetch — backend overlay at build time replaces
          # Exa with SearXNG. Reachable over tailnet; thunderbolt_server_user
          # is in the searxng-clients ACL group.
          env {
            name  = "SEARXNG_URL"
            value = "https://${var.searxng_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }

          port {
            container_port = 8000
            name           = "http"
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }

          readiness_probe {
            http_get {
              path = "/v1/health"
              port = 8000
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            failure_threshold     = 6
          }
        }

        # Tailscale sidecar — registers as `thunderbolt-backend` under
        # thunderbolt_server_user so the backend can reach `searxng.hs.<magic>`
        # (and any other tailnet service) over the tailnet for Pro-mode search.
        container {
          name  = "tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "thunderbolt-backend-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.thunderbolt_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = "thunderbolt-backend"
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
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.thunderbolt_secret_provider.manifest.metadata.name
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
    kubernetes_manifest.thunderbolt_secret_provider,
    kubernetes_deployment.thunderbolt_postgres,
    kubernetes_deployment.thunderbolt_powersync,
    kubernetes_deployment.thunderbolt_keycloak,
    kubernetes_manifest.thunderbolt_backend_build,
  ]
}

resource "kubernetes_service" "thunderbolt_backend" {
  metadata {
    name      = "thunderbolt-backend"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }
  spec {
    selector = {
      app = "thunderbolt-backend"
    }
    port {
      port        = 8000
      target_port = 8000
    }
  }
}
