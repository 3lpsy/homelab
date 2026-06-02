# In-cluster build pipeline for the nextcloud custom image. Uses the shared
# templates/buildkit-job module — see services/builder-buildkitd-config.tf
# for buildkitd.toml mirror config + `local.buildkit_job_shared`.

module "nextcloud_build" {
  source = "./../templates/buildkit-job"

  name      = "nextcloud"
  image_ref = local.nextcloud_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/nextcloud/Dockerfile")
  }

  # Bigger image, longer pulls than the MCP Pythons.
  resources = {
    requests = { cpu = "300m", memory = "768Mi" }
    limits   = { cpu = "3", memory = "3Gi" }
  }
  timeout = "20m"

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
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
          image_pull_policy = "Always"

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

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
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
              secretProviderClass = module.nextcloud_tls_vault.spc_name
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
          image_pull_policy = "Always"

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

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
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
              secretProviderClass = module.nextcloud_tls_vault.spc_name
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
    module.nextcloud_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      metadata[0].name
    ]
  }
}

# Reconciles the user_oidc app's Zitadel provider config + the app-level
# toggles. `occ user_oidc:provider` upserts by name, and `config:app:set`
# is naturally idempotent, so this Job is safe to re-run on every apply.
# Mirrors the configure-collabora shape (same image, same `until php occ
# status` wait loop, same SA + image-pull-secret + PVC + CSI mount). The
# pod template carries `app = "nextcloud-configure-oidc"` so the
# nextcloud_to_oidc egress NetworkPolicy (matchExpression) covers it
# without including it in the nextcloud Service endpoints.
resource "kubernetes_job" "nextcloud_configure_oidc" {
  metadata {
    name      = "configure-oidc-${formatdate("YYYYMMDDhhmmss", timestamp())}"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    backoff_limit = 5

    template {
      # Distinct label from the main Deployment so the nextcloud Service
      # selector (`app = nextcloud`) does NOT pick this Job pod up as an
      # endpoint. The nextcloud-to-oidc egress netpol uses a matchExpression
      # covering both `nextcloud` and `nextcloud-configure-oidc`.
      metadata {
        labels = { app = "nextcloud-configure-oidc" }
      }

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name
        restart_policy       = "OnFailure"

        image_pull_secrets {
          name = kubernetes_secret.registry_pull_secret.metadata[0].name
        }

        # Same Zitadel ClusterIP pin as the deployment — the configure-oidc
        # script doesn't talk to the IdP directly, but `occ user_oidc:provider
        # ... --discoveryuri=...` triggers an immediate fetch of the discovery
        # doc to validate the issuer. That fetch must short-circuit Tailscale.
        host_aliases {
          ip = data.terraform_remote_state.vault_conf.outputs.zitadel_cluster_ip
          hostnames = [
            "${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          ]
        }

        container {
          name  = "configure"
          image = local.nextcloud_image
          image_pull_policy = "Always"

          command = [
            "sh",
            "-c",
            <<-EOT
              set -e
              until php occ status 2>/dev/null; do
                echo "Waiting for Nextcloud to be ready..."
                sleep 10
              done

              CLIENT_ID="$(cat /mnt/secrets/oidc_client_id)"
              CLIENT_SECRET="$(cat /mnt/secrets/oidc_client_secret)"
              DISCOVERY="$${OIDC_ISSUER_URL}/.well-known/openid-configuration"

              echo "Configuring user_oidc app..."

              # `app:install` is one-shot; subsequent runs error harmlessly.
              # `app:enable` is idempotent and brings a previously-disabled
              # app back online without trying to re-install it.
              php occ app:install user_oidc 2>/dev/null || true
              php occ app:enable user_oidc

              # Upsert by name. user_oidc treats a re-create with the same
              # name as a patch, so this both creates the provider on day 1
              # and rotates client_id/secret on subsequent applies.
              # Flag names are version-sensitive: in user_oidc 7.x there's
              # no `--mapping-name`, and the display-name flag is spelled
              # `--mapping-display-name` (with the dash). Run `occ
              # user_oidc:provider --help` inside the container to see the
              # full list before adding more mappings.
              #
              # `--unique-uid=0` uses the raw mapping-uid claim value as the
              # local username instead of `hash(provider_id + claim)`. We're
              # single-provider so collisions are impossible.
              # `--mapping-uid=email` makes the Nextcloud username readable
              # (e.g. `jim@example.com`) instead of Zitadel's numeric sub.
              # If we ever want a stable id that survives an email change,
              # switch to `sub`; for a single personal-user setup, email is
              # the cleaner choice.
              php occ user_oidc:provider zitadel \
                --clientid="$${CLIENT_ID}" \
                --clientsecret="$${CLIENT_SECRET}" \
                --discoveryuri="$${DISCOVERY}" \
                --scope="openid profile email" \
                --unique-uid=0 \
                --mapping-uid=email \
                --mapping-email=email \
                --mapping-display-name=name

              # App-level toggles. soft_auto_provision lets user_oidc reuse
              # an existing local username if one matches the OIDC `sub`
              # (no-op for our chosen mapping). allow_multiple_user_backends
              # keeps the local admin's password login as break-glass.
              # enrich_login_id_token_with_userinfo: Zitadel sends the email
              # + name claims via the userinfo endpoint, NOT in the id_token
              # by default. Without this flag user_oidc tries to provision
              # the user from id_token claims alone, finds no email, and
              # 403s with "Failed to provision the user". Setting this makes
              # user_oidc fetch /oidc/v1/userinfo and merge before provisioning.
              php occ config:app:set user_oidc allow_multiple_user_backends      --value=1
              php occ config:app:set user_oidc soft_auto_provision                --value=1
              php occ config:app:set user_oidc auto_provision                     --value=1
              php occ config:app:set user_oidc single_logout                      --value=1
              # `enrich_login_id_token_with_userinfo` is read from SYSTEM config
              # (config.php), not app config — see user_oidc 8.10
              # LoginController.php:541 (`$oidcSystemConfig[...]`). A
              # `config:app:set` write here is a silent no-op: the key lands
              # in `oc_appconfig` while LoginController reads from
              # `getSystemValue('user_oidc')`. Without this, Zitadel's id_token
              # arrives without `email`, the email-mapping uid is empty, and
              # provisionUser() returns null → "Failed to provision the user".
              php occ config:system:set user_oidc enrich_login_id_token_with_userinfo --value=true --type=boolean
              php occ config:app:set user_oidc login_label                        --value="Login with Zitadel"

              echo "user_oidc configuration completed:"
              php occ user_oidc:provider --output=json
            EOT
          ]

          env {
            name  = "OIDC_ISSUER_URL"
            value = "https://${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }

          # Postgres + Redis env mirrors the deployment exactly. The
          # upstream Nextcloud image's entrypoint runs on every boot and,
          # if any of these are missing, re-writes /var/www/html/config/config.php
          # with empty values for them — which causes occ's bootstrap to fail
          # with `NOAUTH Authentication required` from the Redis client.
          # Keep this list in sync with kubernetes_deployment.nextcloud.
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
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.nextcloud_tls_vault.config_secret_name
                key  = "postgres_password"
              }
            }
          }
          env {
            name  = "REDIS_HOST"
            value = "redis"
          }
          env {
            name = "REDIS_HOST_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.nextcloud_tls_vault.config_secret_name
                key  = "redis_password"
              }
            }
          }
          env {
            name  = "REDIS_HOST_PORT"
            value = "6379"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
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
              secretProviderClass = module.nextcloud_tls_vault.spc_name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment.nextcloud,
    module.nextcloud_tls_vault,
    zitadel_application_oidc.nextcloud,
  ]

  # Default 1m TF wait isn't enough — the `until php occ status` loop alone
  # commonly takes 30-60s after a fresh pod restart, and `occ user_oidc:provider
  # … --discoveryuri=…` validates the issuer on create. 10m gives plenty of
  # headroom for both.
  timeouts {
    create = "10m"
    update = "10m"
  }

  lifecycle {
    ignore_changes = [
      metadata[0].name
    ]
  }
}
