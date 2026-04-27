resource "kubernetes_deployment" "thunderbolt_keycloak" {
  metadata {
    name      = "thunderbolt-keycloak"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "thunderbolt-keycloak"
      }
    }

    template {
      metadata {
        labels = {
          app = "thunderbolt-keycloak"
        }
        annotations = {
          "secret.reloader.stakater.com/reload" = "thunderbolt-secrets"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.thunderbolt.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "thunderbolt_keycloak_admin_password"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Render the realm import JSON from a placeholder template to an
        # emptyDir, substituting OIDC client secret + seed user password
        # from env vars (sourced from the Vault-CSI-synced thunderbolt-secrets).
        # Keeps both credentials out of the keycloak-realm ConfigMap so the
        # ConfigMap is safe to ship in Velero backup tarballs.
        init_container {
          name  = "render-realm"
          image = var.image_busybox
          command = ["sh", "/scripts/render-realm.sh"]

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
            name = "SEED_USER_PASSWORD"
            value_from {
              secret_key_ref {
                name = "thunderbolt-secrets"
                key  = "seed_user_password"
              }
            }
          }
          env {
            name  = "ADMIN_EMAIL"
            value = local.thunderbolt_admin_email
          }
          env {
            name  = "PUBLIC_URL"
            value = local.thunderbolt_public_url
          }

          volume_mount {
            name       = "keycloak-realm-template"
            mount_path = "/template"
            read_only  = true
          }
          volume_mount {
            name       = "keycloak-realm-rendered"
            mount_path = "/rendered"
          }
          volume_mount {
            name       = "keycloak-render-script"
            mount_path = "/scripts"
            read_only  = true
          }
        }

        container {
          name  = "keycloak"
          image = var.image_keycloak

          args = ["start", "--import-realm"]

          env {
            name  = "KC_DB"
            value = "postgres"
          }
          env {
            name  = "KC_DB_URL"
            value = "jdbc:postgresql://thunderbolt-postgres:5432/keycloak"
          }
          env {
            name  = "KC_DB_USERNAME"
            value = "keycloak"
          }
          env {
            name = "KC_DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = "thunderbolt-secrets"
                key  = "keycloak_db_password"
              }
            }
          }

          env {
            name  = "KC_HOSTNAME"
            value = local.thunderbolt_public_url
          }
          env {
            name  = "KC_HOSTNAME_BACKCHANNEL_DYNAMIC"
            value = "true"
          }
          env {
            name  = "KC_HTTP_ENABLED"
            value = "true"
          }
          env {
            name  = "KC_PROXY_HEADERS"
            value = "xforwarded"
          }
          env {
            name  = "KC_HEALTH_ENABLED"
            value = "true"
          }

          env {
            name = "KC_BOOTSTRAP_ADMIN_USERNAME"
            value_from {
              secret_key_ref {
                name = "thunderbolt-secrets"
                key  = "keycloak_admin_username"
              }
            }
          }
          env {
            name = "KC_BOOTSTRAP_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = "thunderbolt-secrets"
                key  = "keycloak_admin_password"
              }
            }
          }

          env {
            name  = "JAVA_OPTS_APPEND"
            value = "-XX:InitialRAMPercentage=25 -XX:MaxRAMPercentage=60"
          }

          # Suppress the org.keycloak.events logger — routine
          # CODE_TO_TOKEN_ERROR / LOGIN_ERROR entries include username,
          # userId, sessionId and ipAddress at WARN. Keeping the root at
          # INFO so other loggers still surface, only the events category
          # is bumped to ERROR. Format is `root,category:level,…`.
          env {
            name  = "KC_LOG_LEVEL"
            value = "INFO,org.keycloak.events:ERROR"
          }

          port {
            container_port = 8080
            name           = "http"
          }

          volume_mount {
            name       = "keycloak-realm-rendered"
            mount_path = "/opt/keycloak/data/import"
            read_only  = true
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "200m"
              memory = "1.5Gi"
            }
            limits = {
              cpu    = "1500m"
              memory = "4Gi"
            }
          }

          readiness_probe {
            http_get {
              path = "/realms/thunderbolt/.well-known/openid-configuration"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 12
          }
        }

        volume {
          name = "keycloak-realm-template"
          config_map {
            name = kubernetes_config_map.thunderbolt_keycloak_realm.metadata[0].name
          }
        }
        volume {
          name = "keycloak-render-script"
          config_map {
            name         = kubernetes_config_map.thunderbolt_keycloak_render_script.metadata[0].name
            default_mode = "0755"
          }
        }
        volume {
          name = "keycloak-realm-rendered"
          empty_dir {}
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
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "thunderbolt_keycloak" {
  metadata {
    name      = "thunderbolt-keycloak"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }
  spec {
    selector = {
      app = "thunderbolt-keycloak"
    }
    port {
      port        = 8080
      target_port = 8080
    }
  }
}
