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
          "build-job"                           = module.thunderbolt_backend_build.job_name
          "secret.reloader.stakater.com/reload" = "thunderbolt-secrets"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.thunderbolt.metadata[0].name

        # Pin searxng + litellm tailnet FQDNs to their Service ClusterIPs
        # so SEARXNG_URL and THUNDERBOLT_INFERENCE_URL keep their
        # FQDN-valid TLS certs (nginx :443 in each target pod) without
        # going through a Tailscale sidecar.
        host_aliases {
          ip        = kubernetes_service.searxng.spec[0].cluster_ip
          hostnames = ["${var.searxng_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"]
        }
        host_aliases {
          ip        = kubernetes_service.litellm.spec[0].cluster_ip
          hostnames = ["${var.litellm_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"]
        }

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
            name  = "DATABASE_DRIVER"
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

          # Chat-completion upstream — route /v1/chat/completions through
          # LiteLLM on the tailnet. Required to stop the `Thunderbolt
          # inference URL or API key not configured` 500s on every request.
          env {
            name  = "THUNDERBOLT_INFERENCE_URL"
            value = "https://${var.litellm_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }
          env {
            name = "THUNDERBOLT_INFERENCE_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.thunderbolt_inference.metadata[0].name
                key  = "api_key"
              }
            }
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
      }
    }
  }

  depends_on = [
    kubernetes_manifest.thunderbolt_secret_provider,
    kubernetes_deployment.thunderbolt_postgres,
    kubernetes_deployment.thunderbolt_powersync,
    kubernetes_deployment.thunderbolt_keycloak,
    module.thunderbolt_backend_build,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
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
