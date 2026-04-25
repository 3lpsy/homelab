# In-cluster build pipeline for the nextcloud custom image.
#
# Mirrors the mcp-searxng / thunderbolt pattern: rootless BuildKit as a k8s
# Job in the `builder` namespace, tailscale native sidecar for registry egress.
# Job name is suffixed with a sha256 of the Dockerfile so terraform only
# re-creates a Job when the Dockerfile content changes.

resource "kubernetes_config_map" "nextcloud_build_context" {
  metadata {
    name      = "nextcloud-build-context"
    namespace = kubernetes_namespace.builder.metadata[0].name
  }
  data = {
    "Dockerfile" = file("${path.module}/../data/images/nextcloud/Dockerfile")
  }
}

locals {
  nextcloud_dockerfile_hash = substr(sha256(file("${path.module}/../data/images/nextcloud/Dockerfile")), 0, 8)
  nextcloud_build_job_name  = "nextcloud-build-${local.nextcloud_dockerfile_hash}"
}

resource "kubernetes_manifest" "nextcloud_build" {
  manifest = {
    apiVersion = "batch/v1"
    kind       = "Job"
    metadata = {
      name      = local.nextcloud_build_job_name
      namespace = kubernetes_namespace.builder.metadata[0].name
    }
    spec = {
      backoffLimit = 2
      ttlSecondsAfterFinished = 3600
      template = {
        metadata = {
          labels = {
            app = "nextcloud-build"
          }
          annotations = {
            "container.apparmor.security.beta.kubernetes.io/buildkit" = "unconfined"
          }
        }
        spec = {
          restartPolicy      = "Never"
          serviceAccountName = kubernetes_service_account.builder.metadata[0].name

          initContainers = [
            {
              name          = "tailscale"
              image         = var.image_tailscale
              restartPolicy = "Always"
              env = [
                { name = "TS_STATE_DIR", value = "/var/lib/tailscale" },
                { name = "TS_KUBE_SECRET", value = "nextcloud-builder-tailscale-state" },
                { name = "TS_USERSPACE", value = "false" },
                {
                  name = "TS_AUTHKEY"
                  valueFrom = {
                    secretKeyRef = {
                      name = kubernetes_secret.builder_tailscale_auth.metadata[0].name
                      key  = "TS_AUTHKEY"
                    }
                  }
                },
                { name = "TS_HOSTNAME", value = "nextcloud-builder" },
                { name = "TS_EXTRA_ARGS", value = "--login-server=https://${data.terraform_remote_state.homelab.outputs.headscale_server_fqdn}" },
              ]
              securityContext = {
                capabilities = {
                  add = ["NET_ADMIN"]
                }
              }
              volumeMounts = [
                { name = "dev-net-tun", mountPath = "/dev/net/tun" },
                { name = "tailscale-state", mountPath = "/var/lib/tailscale" },
              ]
            },
            {
              name    = "wait-for-tailscale"
              image   = var.image_busybox
              command = ["sh", "-c", "until nslookup ${local.thunderbolt_registry}; do echo 'waiting for tailscale dns'; sleep 2; done"]
            },
          ]

          containers = [
            {
              name    = "buildkit"
              image   = "moby/buildkit:rootless"
              command = ["buildctl-daemonless.sh"]
              args = [
                "build",
                "--frontend=dockerfile.v0",
                "--local=context=/workspace",
                "--local=dockerfile=/workspace",
                "--output=type=image,name=${local.nextcloud_image},push=true",
              ]
              env = [
                { name = "BUILDKITD_FLAGS", value = "--oci-worker-no-process-sandbox" },
              ]
              securityContext = {
                runAsUser  = 1000
                runAsGroup = 1000
                seccompProfile = {
                  type = "Unconfined"
                }
              }
              volumeMounts = [
                { name = "dockerfile", mountPath = "/workspace", readOnly = true },
                { name = "docker-config", mountPath = "/home/user/.docker", readOnly = true },
              ]
              resources = {
                requests = { cpu = "300m", memory = "768Mi" }
                limits   = { cpu = "3", memory = "3Gi" }
              }
            },
          ]

          volumes = [
            {
              name = "dockerfile"
              configMap = {
                name = kubernetes_config_map.nextcloud_build_context.metadata[0].name
              }
            },
            {
              name = "docker-config"
              secret = {
                secretName = kubernetes_secret.builder_registry_pull_secret.metadata[0].name
                items = [
                  { key = ".dockerconfigjson", path = "config.json" },
                ]
              }
            },
            {
              name = "dev-net-tun"
              hostPath = {
                path = "/dev/net/tun"
                type = "CharDevice"
              }
            },
            {
              name     = "tailscale-state"
              emptyDir = {}
            },
          ]
        }
      }
    }
  }

  computed_fields = [
    "metadata.labels",
    "metadata.annotations",
    "spec.template.metadata.labels",
    "spec.selector",
  ]

  wait {
    condition {
      type   = "Complete"
      status = "True"
    }
  }

  timeouts {
    create = "20m"
    update = "20m"
  }

  depends_on = [
    kubernetes_namespace.builder,
    kubernetes_role_binding.builder_tailscale,
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_secret.builder_tailscale_auth,
    kubernetes_config_map.nextcloud_build_context,
  ]
}

resource "kubernetes_job" "nextcloud_configure_collabora" {
  metadata {
    name      = "configure-collabora-${formatdate("YYYYMMDDhhmmss", timestamp())}"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    backoff_limit = 5

    template {
      metadata {}

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name
        restart_policy       = "OnFailure"

        image_pull_secrets {
          name = kubernetes_secret.registry_pull_secret.metadata[0].name
        }

        container {
          name  = "configure"
          image = local.nextcloud_image

          command = [
            "sh",
            "-c",
            <<-EOT
              until php occ status 2>/dev/null; do
                echo "Waiting for Nextcloud to be ready..."
                sleep 10
              done

              php occ config:system:set default_language --value="en"
              php occ config:system:set default_locale --value="en_US"
              php occ config:system:set force_language --value="en"

              # Reduce log noise: 0=debug, 1=info, 2=warn, 3=error, 4=fatal.
              php occ config:system:set loglevel --value=2 --type=integer

              echo "Configuring Collabora Office app..."

              php occ app:install richdocuments || echo "Collabora already installed"
              php occ app:enable richdocuments

              php occ config:app:set richdocuments wopi_url --value="https://${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
              php occ config:app:set richdocuments public_wopi_url --value="https://${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"

              php occ config:system:set allow_local_remote_servers --value=true --type=boolean

              php occ config:system:set overwriteprotocol --value=https
              php occ config:system:set overwrite.cli.url --value="https://${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"

              php occ config:system:set trusted_domains 2 --value="${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"

              php occ config:app:set richdocuments wopi_allowlist --value="127.0.0.1,::1,localhost,${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain},${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain},10.43.0.0/16,10.42.0.0/16,100.64.0.0/10"
              php occ config:app:set richdocuments doc_format --value="ooxml"

              php occ config:app:delete richdocuments discovery || true
              php occ config:app:delete richdocuments discovery_parsed || true
              php occ richdocuments:activate-config

              echo "Collabora configuration completed:"
              php occ config:app:get richdocuments wopi_url
              php occ config:app:get richdocuments public_wopi_url
              php occ config:app:get richdocuments wopi_allowlist
              php occ config:system:get allow_local_remote_servers
              php occ config:system:get trusted_domains

            EOT
          ]

          env {
            name  = "POSTGRES_HOST"
            value = "postgres"
          }

          env {
            name  = "POSTGRES_DB"
            value = "nextcloud"
          }

          env {
            name  = "POSTGRES_USER"
            value = "nextcloud"
          }

          env {
            name  = "REDIS_HOST"
            value = "redis"
          }

          volume_mount {
            name       = "nextcloud-data"
            mount_path = "/var/www/html"
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        volume {
          name = "nextcloud-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.nextcloud_data.metadata[0].name
          }
        }

        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.nextcloud_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment.nextcloud,
    kubernetes_deployment.collabora
  ]

  lifecycle {
    ignore_changes = [
      metadata[0].name
    ]
  }
}

resource "kubernetes_job" "nextcloud_configure_previews" {
  metadata {
    name      = "configure-previews-${formatdate("YYYYMMDDhhmmss", timestamp())}"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    backoff_limit = 5

    template {
      metadata {}

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name
        restart_policy       = "OnFailure"

        image_pull_secrets {
          name = kubernetes_secret.registry_pull_secret.metadata[0].name
        }

        container {
          name  = "configure"
          image = local.nextcloud_image

          command = [
            "sh",
            "-c",
            <<-EOT
              until php occ status 2>/dev/null; do
                echo "Waiting for Nextcloud to be ready..."
                sleep 10
              done

              echo "Configuring preview providers..."

              php occ config:system:set enabledPreviewProviders 0 --value="OC\Preview\PNG"
              php occ config:system:set enabledPreviewProviders 1 --value="OC\Preview\JPEG"
              php occ config:system:set enabledPreviewProviders 2 --value="OC\Preview\GIF"
              php occ config:system:set enabledPreviewProviders 3 --value="OC\Preview\BMP"
              php occ config:system:set enabledPreviewProviders 4 --value="OC\Preview\XBitmap"
              php occ config:system:set enabledPreviewProviders 5 --value="OC\Preview\MarkDown"
              php occ config:system:set enabledPreviewProviders 6 --value="OC\Preview\MP3"
              php occ config:system:set enabledPreviewProviders 7 --value="OC\Preview\TXT"
              php occ config:system:set enabledPreviewProviders 8 --value="OC\Preview\Movie"
              php occ config:system:set enabledPreviewProviders 9 --value="OC\Preview\MP4"
              php occ config:system:set enabledPreviewProviders 10 --value="OC\Preview\MOV"
              php occ config:system:set enabledPreviewProviders 11 --value="OC\Preview\HEIC"
              php occ config:app:set richdocuments preview_enabled --value=no

              php occ config:system:set enable_previews --value=true --type=boolean
              php occ config:system:set "preview_disabled_mime_types" 0 --value="application/pdf"

              echo "Preview providers configured:"
              php occ config:system:get enabledPreviewProviders
            EOT
          ]

          env {
            name  = "POSTGRES_HOST"
            value = "postgres"
          }

          env {
            name  = "POSTGRES_DB"
            value = "nextcloud"
          }

          env {
            name  = "POSTGRES_USER"
            value = "nextcloud"
          }

          env {
            name  = "REDIS_HOST"
            value = "redis"
          }

          volume_mount {
            name       = "nextcloud-data"
            mount_path = "/var/www/html"
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        volume {
          name = "nextcloud-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.nextcloud_data.metadata[0].name
          }
        }

        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.nextcloud_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment.nextcloud,
    kubernetes_service.nextcloud_postgres,
    kubernetes_service.nextcloud_redis,
    kubernetes_manifest.nextcloud_secret_provider
  ]

  lifecycle {
    ignore_changes = [
      metadata[0].name
    ]
  }
}
