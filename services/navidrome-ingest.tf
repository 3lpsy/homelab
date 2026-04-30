resource "kubernetes_deployment" "navidrome_ingest" {
  metadata {
    name      = "navidrome-ingest"
    namespace = kubernetes_namespace.navidrome.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "navidrome-ingest" }
    }

    template {
      metadata {
        labels = { app = "navidrome-ingest" }
        annotations = {
          "build-job"                              = module.navidrome_ingest_build.job_name
          "prompt-hash"                            = sha1(kubernetes_config_map.navidrome_ingest_prompt.data["prompt.j2"])
          "secret.reloader.stakater.com/reload"    = "navidrome-ingest-secrets"
          "configmap.reloader.stakater.com/reload" = "navidrome-ingest-prompt"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.navidrome_ingest.metadata[0].name

        image_pull_secrets {
          name = kubernetes_secret.navidrome_ingest_registry_pull_secret.metadata[0].name
        }

        # host_aliases: pin both upstream FQDNs to in-cluster Service
        # ClusterIPs so LITELLM_BASE_URL and INGEST_BASE_URL keep using
        # FQDN-valid TLS certs without a tailscale egress hop. Mirrors
        # services/mcp-litellm.tf:105-110.
        host_aliases {
          ip        = kubernetes_service.litellm.spec[0].cluster_ip
          hostnames = ["${var.litellm_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"]
        }
        host_aliases {
          ip        = kubernetes_service.ingest_ui_internal.spec[0].cluster_ip
          hostnames = ["${var.ingest_ui_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"]
        }

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "litellm_api_key"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Ensure /music exists with worker UID ownership. Dropzone is no
        # longer mounted — pulled over HTTP from ingest-ui's internal API.
        init_container {
          name  = "init-dirs"
          image = var.image_busybox
          command = [
            "sh", "-c",
            "mkdir -p /music && chown -R 1000:1000 /music",
          ]
          volume_mount {
            name       = "navidrome-music"
            mount_path = "/music"
          }
        }

        container {
          name              = "navidrome-ingest"
          image             = local.navidrome_ingest_image
          image_pull_policy = "Always"

          env {
            name  = "MUSIC_PATH"
            value = "/music"
          }
          env {
            name  = "PROMPT_PATH"
            value = "/etc/ingest/prompt.j2"
          }
          env {
            name  = "SCHEMA_PATH"
            value = "/etc/ingest/schema.json"
          }
          env {
            name  = "LITELLM_BASE_URL"
            value = "https://${var.litellm_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }
          env {
            name  = "LITELLM_MODEL"
            value = var.navidrome_ingest_model
          }
          env {
            name  = "CONFIDENCE_THRESHOLD"
            value = tostring(var.navidrome_ingest_confidence_threshold)
          }
          env {
            name  = "INGEST_BASE_URL"
            value = "https://${var.ingest_ui_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }
          env {
            name  = "POLL_INTERVAL"
            value = "30"
          }
          env {
            name  = "LOG_LEVEL"
            value = "info"
          }
          env {
            name = "LITELLM_API_KEY"
            value_from {
              secret_key_ref {
                name = "navidrome-ingest-secrets"
                key  = "litellm_api_key"
              }
            }
          }
          env {
            name = "INGEST_INTERNAL_TOKEN"
            value_from {
              secret_key_ref {
                name = "navidrome-ingest-secrets"
                key  = "ingest_internal_token"
              }
            }
          }

          port {
            container_port = 8090
            name           = "health"
          }

          security_context {
            run_as_user  = 1000
            run_as_group = 1000
          }

          volume_mount {
            name       = "navidrome-music"
            mount_path = "/music"
          }
          volume_mount {
            name       = "prompt"
            mount_path = "/etc/ingest"
            read_only  = true
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1000m", memory = "1Gi" }
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8090
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8090
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }

        # Volumes
        volume {
          name = "navidrome-music"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.navidrome_music.metadata[0].name
          }
        }
        volume {
          name = "prompt"
          config_map {
            name = kubernetes_config_map.navidrome_ingest_prompt.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.navidrome_ingest_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.navidrome_ingest_secret_provider,
    module.navidrome_ingest_build,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}
