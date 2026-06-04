# Namespace + shared RBAC

resource "kubernetes_namespace" "thunderbolt" {
  metadata {
    name = "thunderbolt"
  }
}

resource "kubernetes_service_account" "thunderbolt" {
  metadata {
    name      = "thunderbolt"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }
  automount_service_account_token = false
}

# Registry pull secret (reuses the "internal" registry user)
resource "kubernetes_secret" "thunderbolt_registry_pull_secret" {
  metadata {
    name      = "registry-pull-secret"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${local.thunderbolt_registry}" = {
          username = "internal"
          password = random_password.registry_user_passwords["internal"].result
          auth     = base64encode("internal:${random_password.registry_user_passwords["internal"].result}")
        }
      }
    })
  }
}

# Random passwords / secrets

resource "random_password" "thunderbolt_postgres" {
  length  = 32
  special = false
}

resource "random_password" "thunderbolt_powersync_role" {
  length  = 32
  special = false
}

resource "random_password" "thunderbolt_better_auth_secret" {
  length  = 48
  special = false
}

resource "random_password" "thunderbolt_powersync_jwt_secret" {
  length  = 48
  special = false
}

module "thunderbolt_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "thunderbolt"
  namespace            = kubernetes_namespace.thunderbolt.metadata[0].name
  service_account_name = kubernetes_service_account.thunderbolt.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.thunderbolt_server_user
}

# Thunderbolt backend points `/v1/chat/completions` at LiteLLM. The backend
# reads the upstream API key from THUNDERBOLT_INFERENCE_API_KEY. Sharing the
# LiteLLM master key today; swap to a scoped virtual key (created via LiteLLM
# admin UI) once the single-user setup grows.
resource "kubernetes_secret" "thunderbolt_inference" {
  metadata {
    name      = "thunderbolt-inference"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }
  type = "Opaque"
  data = {
    api_key = "sk-${random_password.litellm_master_key.result}"
  }
}

module "thunderbolt_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "thunderbolt"
  namespace            = kubernetes_namespace.thunderbolt.metadata[0].name
  service_account_name = kubernetes_service_account.thunderbolt.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = local.thunderbolt_fqdn
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  config_secrets = {
    postgres_password        = random_password.thunderbolt_postgres.result
    powersync_role_password  = random_password.thunderbolt_powersync_role.result
    better_auth_secret       = random_password.thunderbolt_better_auth_secret.result
    oidc_client_id           = zitadel_application_oidc.thunderbolt.client_id
    oidc_client_secret       = zitadel_application_oidc.thunderbolt.client_secret
    powersync_jwt_secret     = random_password.thunderbolt_powersync_jwt_secret.result
    powersync_jwt_secret_b64 = base64encode(random_password.thunderbolt_powersync_jwt_secret.result)
    database_url             = "postgresql://postgres:${random_password.thunderbolt_postgres.result}@thunderbolt-postgres:5432/thunderbolt"
    powersync_database_url   = "postgresql://powersync_role:${random_password.thunderbolt_powersync_role.result}@thunderbolt-postgres:5432/thunderbolt"
  }

  providers = { acme = acme }
}

# ─── Zitadel project + OIDC application + per-user grants ────────────────────
#
# Per memory `feedback_zitadel_one_project_per_service`, each service onboarded
# to Zitadel SSO declares its own project. With VITE_AUTH_MODE=sso the backend
# drives auth through Better Auth's SSO plugin (provider id "sso"), whose
# callback is:
#   ${BETTER_AUTH_URL}/v1/api/auth/sso/callback/sso
# (NOT the legacy genericOAuth path /v1/api/auth/oauth2/callback/oidc — that was
# the pre-SSO-mode value. The old path is kept registered below as a revert-
# safety fallback; harmless if unused.)

resource "zitadel_project" "thunderbolt" {
  name   = "thunderbolt"
  org_id = data.zitadel_organizations.homelab.ids[0]

  project_role_assertion   = false
  project_role_check       = false
  has_project_check        = false
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"
}

resource "zitadel_application_oidc" "thunderbolt" {
  name       = "Thunderbolt"
  org_id     = data.zitadel_organizations.homelab.ids[0]
  project_id = zitadel_project.thunderbolt.id

  redirect_uris = [
    "${local.thunderbolt_public_url}/v1/api/auth/sso/callback/sso",     # SSO-plugin path (VITE_AUTH_MODE=sso)
    "${local.thunderbolt_public_url}/v1/api/auth/oauth2/callback/oidc", # legacy genericOAuth path (revert fallback)
  ]
  post_logout_redirect_uris = ["${local.thunderbolt_public_url}/"]

  response_types = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types = [
    "OIDC_GRANT_TYPE_AUTHORIZATION_CODE",
    "OIDC_GRANT_TYPE_REFRESH_TOKEN",
  ]
  app_type         = "OIDC_APP_TYPE_WEB"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_BASIC"
  version          = "OIDC_VERSION_1_0"

  access_token_type           = "OIDC_TOKEN_TYPE_BEARER"
  access_token_role_assertion = false
  id_token_role_assertion     = false
  id_token_userinfo_assertion = false

  dev_mode = false
}

resource "zitadel_user_grant" "thunderbolt_personal_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.personal.id
  project_id = zitadel_project.thunderbolt.id
  role_keys  = []
}

resource "zitadel_user_grant" "thunderbolt_partner_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.partner.id
  project_id = zitadel_project.thunderbolt.id
  role_keys  = []
}

# In-cluster build pipelines for the thunderbolt frontend and backend images.
# Both Dockerfiles do `git clone` at build time, so the build context only
# needs the Dockerfile itself plus any overlay files the image COPYs
# (frontend: nginx.conf; backend: exa-override.ts). A separate git ref is
# pinned via var.thunderbolt_ref — passed as both a build-arg and as
# `context_hash_extra` so a ref change triggers a rebuild even when nothing
# in the build context changed.
#
# Force a rebuild by touching any context file or bumping var.thunderbolt_ref.
# Old completed Jobs accumulate; clean periodically with:
#   kubectl delete jobs -n builder --field-selector status.successful=1

module "thunderbolt_frontend_build" {
  source = "./../templates/buildkit-job"

  name      = "thunderbolt-frontend"
  image_ref = local.thunderbolt_frontend_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/thunderbolt/frontend/Dockerfile")
    "nginx.conf" = file("${path.module}/../data/images/thunderbolt/frontend/nginx.conf")
  }

  build_args = {
    THUNDERBOLT_REF = var.thunderbolt_ref
    # npm registry → in-cluster Verdaccio proxy (resolved via the npm host_alias
    # in local.buildkit_job_shared). Same FQDN form opencode uses. docs/DEP_SAFETY.md
    NPM_REGISTRY = "https://${var.npm_domain}.${local.magic_fqdn_suffix}/"
  }
  context_hash_extra = var.thunderbolt_ref

  resources = {
    requests = { cpu = "1", memory = "2Gi" }
    limits   = { cpu = "8", memory = "12Gi" }
  }
  timeout = "20m"

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}

module "thunderbolt_backend_build" {
  source = "./../templates/buildkit-job"

  name      = "thunderbolt-backend"
  image_ref = local.thunderbolt_backend_image

  context_files = {
    "Dockerfile"      = file("${path.module}/../data/images/thunderbolt/backend/Dockerfile")
    "exa-override.ts" = file("${path.module}/../data/images/thunderbolt/backend/exa-override.ts")
  }

  build_args = {
    THUNDERBOLT_REF = var.thunderbolt_ref
    # npm registry → in-cluster Verdaccio proxy (resolved via the npm host_alias
    # in local.buildkit_job_shared). Same FQDN form opencode uses. docs/DEP_SAFETY.md
    NPM_REGISTRY = "https://${var.npm_domain}.${local.magic_fqdn_suffix}/"
  }
  context_hash_extra = var.thunderbolt_ref

  resources = {
    requests = { cpu = "1", memory = "2Gi" }
    limits   = { cpu = "6", memory = "8Gi" }
  }
  timeout = "20m"

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}

resource "kubernetes_persistent_volume_claim" "thunderbolt_postgres_data" {
  # lifecycle {
  #   prevent_destroy = true
  # }
  metadata {
    name      = "thunderbolt-postgres-data"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = "20Gi"
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_persistent_volume_claim" "thunderbolt_mongo_data" {
  # lifecycle {
  #   prevent_destroy = true
  # }
  metadata {
    name      = "thunderbolt-mongo-data"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_config_map" "thunderbolt_nginx_config" {
  metadata {
    name      = "thunderbolt-nginx-config"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/thunderbolt.nginx.conf.tpl", {
      server_domain       = local.thunderbolt_fqdn
      nginx_logging_block = local.nginx_logging_blocks["thunderbolt"]
    })
  }
}

resource "kubernetes_config_map" "thunderbolt_postgres_init" {
  metadata {
    name      = "thunderbolt-postgres-init"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  # Static shell script — no template interpolation. The script reads the
  # PowerSync role password from /mnt/secrets/* (Vault CSI) at runtime and
  # feeds it to psql via a -v variable, so the ConfigMap contains zero
  # credential material.
  data = {
    "01-powersync.sh" = file("${path.module}/../data/thunderbolt/postgres-init.sh")
  }
}

resource "kubernetes_config_map" "thunderbolt_powersync_config" {
  metadata {
    name      = "thunderbolt-powersync-config"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  # Static YAML — no template interpolation. PowerSync resolves
  # !env POWERSYNC_DATABASE_URI and !env POWERSYNC_JWT_KEY_B64 at startup
  # from env vars sourced from the Vault-CSI-synced thunderbolt-secrets
  # k8s Secret. No credential material lands in the ConfigMap.
  data = {
    "config.yaml" = file("${path.module}/../data/thunderbolt/powersync-config.yaml")
  }
}

resource "kubernetes_deployment" "thunderbolt_postgres" {
  metadata {
    name      = "thunderbolt-postgres"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "thunderbolt-postgres"
      }
    }

    template {
      metadata {
        labels = {
          app = "thunderbolt-postgres"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.thunderbolt.metadata[0].name

        # Pinned to artemis (Phase-4 migration). Data is NOT migrated — the
        # thunderbolt-postgres-data / thunderbolt-mongo-data PVCs are node-bound
        # local-path and are recreated fresh on artemis; postgres-init.sh, the
        # mongo rs.initiate Job, and Better Auth bootstrap all re-run clean.
        # node_selector pulls onto artemis; toleration clears gpu=true:NoSchedule.
        # See docs/CLUSTER.md.
        node_selector = { node = "artemis" }
        toleration {
          key      = "gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "postgres_password"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        container {
          name  = "postgres"
          image = var.image_thunderbolt_postgres
          image_pull_policy = "Always"

          args = ["postgres", "-c", "wal_level=logical"]

          env {
            name  = "POSTGRES_DB"
            value = "thunderbolt"
          }

          env {
            name  = "POSTGRES_USER"
            value = "postgres"
          }

          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.thunderbolt_tls_vault.config_secret_name
                key  = "postgres_password"
              }
            }
          }

          port {
            container_port = 5432
          }

          volume_mount {
            name       = "postgres-data"
            # PG18+: mount at parent dir; postgres creates /<MAJOR>/docker/ subdir.
            mount_path = "/var/lib/postgresql"
          }
          volume_mount {
            name       = "postgres-init"
            mount_path = "/docker-entrypoint-initdb.d"
            read_only  = true
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }

          liveness_probe {
            exec {
              command = ["pg_isready", "-U", "postgres"]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          readiness_probe {
            exec {
              command = ["pg_isready", "-U", "postgres"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }

        volume {
          name = "postgres-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.thunderbolt_postgres_data.metadata[0].name
          }
        }
        volume {
          name = "postgres-init"
          config_map {
            name         = kubernetes_config_map.thunderbolt_postgres_init.metadata[0].name
            default_mode = "0755"
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.thunderbolt_tls_vault.spc_name
            }
          }
        }
      }
    }
  }

  depends_on = [
    module.thunderbolt_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "thunderbolt_postgres" {
  metadata {
    name      = "thunderbolt-postgres"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }
  spec {
    selector = {
      app = "thunderbolt-postgres"
    }
    port {
      port        = 5432
      target_port = 5432
    }
  }
}

resource "kubernetes_deployment" "thunderbolt_mongo" {
  metadata {
    name      = "thunderbolt-mongo"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "thunderbolt-mongo"
      }
    }

    template {
      metadata {
        labels = {
          app = "thunderbolt-mongo"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.thunderbolt.metadata[0].name

        # Pinned to artemis (Phase-4). Fresh PVC on artemis; rs.initiate re-runs.
        node_selector = { node = "artemis" }
        toleration {
          key      = "gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        # Set pod hostname to the Service name so mongo can identify itself as
        # an RS member: member host `thunderbolt-mongo:27017` matches /etc/hosts
        # entry for the pod IP. Without this, mongo sees member host resolve
        # only to the Service ClusterIP (not a local interface) and declares
        # the RS config invalid (`info: "Does not have a valid replica set config"`).
        hostname = "thunderbolt-mongo"

        container {
          name  = "mongo"
          image = var.image_mongo
          image_pull_policy = "Always"

          args = ["--replSet", "rs0", "--bind_ip_all", "--quiet"]

          port {
            container_port = 27017
          }

          volume_mount {
            name       = "mongo-data"
            mount_path = "/data/db"
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

          startup_probe {
            exec {
              command = ["mongosh", "--quiet", "--eval", "db.adminCommand('ping').ok"]
            }
            period_seconds    = 5
            failure_threshold = 24
            timeout_seconds   = 5
          }

          readiness_probe {
            exec {
              command = ["mongosh", "--quiet", "--eval", "db.adminCommand('ping').ok"]
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }

        volume {
          name = "mongo-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.thunderbolt_mongo_data.metadata[0].name
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "thunderbolt_mongo" {
  metadata {
    name      = "thunderbolt-mongo"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }
  spec {
    selector = {
      app = "thunderbolt-mongo"
    }
    port {
      port        = 27017
      target_port = 27017
    }
  }
}

# One-shot replica-set init. Idempotent: rs.status() check short-circuits.
# Uses timestamp() in the name so each `terraform apply` creates a new job and
# old completed ones accumulate — clean up periodically:
#   kubectl delete jobs -n thunderbolt --field-selector status.successful=1
resource "kubernetes_job" "thunderbolt_mongo_rs_init" {
  metadata {
    name      = "thunderbolt-mongo-rs-init-${substr(sha1(timestamp()), 0, 8)}"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  spec {
    backoff_limit = 5
    template {
      metadata {
        labels = {
          app = "thunderbolt-mongo-rs-init"
        }
      }
      spec {
        restart_policy       = "OnFailure"
        service_account_name = kubernetes_service_account.thunderbolt.metadata[0].name

        # Must run on artemis alongside the mongo pod (same node).
        node_selector = { node = "artemis" }
        toleration {
          key      = "gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        container {
          name  = "mongo-rs-init"
          image = var.image_mongo
          image_pull_policy = "Always"
          command = [
            "bash", "-c",
            "until mongosh --host thunderbolt-mongo:27017 --eval 'db.adminCommand({ping:1})' >/dev/null 2>&1; do echo waiting for mongo; sleep 2; done; mongosh --host thunderbolt-mongo:27017 --eval 'try{rs.status().ok&&quit(0)}catch{}rs.initiate({_id:\"rs0\",version:1,members:[{_id:0,host:\"thunderbolt-mongo:27017\"}]})'"
          ]

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
        }
      }
    }
  }

  wait_for_completion = false

  lifecycle {
    ignore_changes = [metadata[0].name]
  }

  depends_on = [
    kubernetes_deployment.thunderbolt_mongo,
    kubernetes_service.thunderbolt_mongo,
  ]
}

resource "kubernetes_deployment" "thunderbolt_powersync" {
  metadata {
    name      = "thunderbolt-powersync"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "thunderbolt-powersync"
      }
    }

    template {
      metadata {
        labels = {
          app = "thunderbolt-powersync"
        }
        annotations = {
          "config-hash"                         = sha1(kubernetes_config_map.thunderbolt_powersync_config.data["config.yaml"])
          "secret.reloader.stakater.com/reload" = "thunderbolt-secrets"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.thunderbolt.metadata[0].name

        # Pinned to artemis (Phase-4) — colocate with postgres it replicates.
        node_selector = { node = "artemis" }
        toleration {
          key      = "gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        container {
          name  = "powersync"
          image = var.image_powersync
          image_pull_policy = "Always"

          args = ["start", "-r", "unified"]

          env {
            name  = "POWERSYNC_CONFIG_PATH"
            value = "/config/config.yaml"
          }
          env {
            name = "PS_DATABASE_URI"
            value_from {
              secret_key_ref {
                name = module.thunderbolt_tls_vault.config_secret_name
                key  = "powersync_database_url"
              }
            }
          }
          env {
            name = "PS_JWT_KEY_B64"
            value_from {
              secret_key_ref {
                name = module.thunderbolt_tls_vault.config_secret_name
                key  = "powersync_jwt_secret_b64"
              }
            }
          }

          port {
            container_port = 8080
            name           = "http"
          }

          volume_mount {
            name       = "powersync-config"
            mount_path = "/config"
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
        }

        volume {
          name = "powersync-config"
          config_map {
            name = kubernetes_config_map.thunderbolt_powersync_config.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment.thunderbolt_postgres,
    kubernetes_job.thunderbolt_mongo_rs_init,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "thunderbolt_powersync" {
  metadata {
    name      = "thunderbolt-powersync"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }
  spec {
    selector = {
      app = "thunderbolt-powersync"
    }
    port {
      port        = 8080
      target_port = 8080
    }
  }
}

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

        # Pinned to artemis (Phase-4) — intra-node to postgres/mongo/powersync;
        # litellm (also on artemis) is now a same-node hop too.
        node_selector = { node = "artemis" }
        toleration {
          key      = "gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        # Pin searxng + litellm + zitadel tailnet FQDNs to their Service
        # ClusterIPs so the backend keeps FQDN-valid TLS certs (nginx :443
        # in each target pod) without going through a Tailscale sidecar.
        # Zitadel is reached during OIDC discovery + token exchange.
        host_aliases {
          ip        = kubernetes_service.searxng.spec[0].cluster_ip
          hostnames = ["${var.searxng_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"]
        }
        host_aliases {
          ip        = kubernetes_service.litellm.spec[0].cluster_ip
          hostnames = ["${var.litellm_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"]
        }
        host_aliases {
          ip        = data.terraform_remote_state.vault_conf.outputs.zitadel_cluster_ip
          hostnames = ["${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"]
        }

        image_pull_secrets {
          name = kubernetes_secret.thunderbolt_registry_pull_secret.metadata[0].name
        }

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "better_auth_secret"
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
          image_pull_policy = "Always"

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
            value = "https://${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"
          }
          env {
            name = "OIDC_CLIENT_ID"
            value_from {
              secret_key_ref {
                name = module.thunderbolt_tls_vault.config_secret_name
                key  = "oidc_client_id"
              }
            }
          }
          env {
            name = "OIDC_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = module.thunderbolt_tls_vault.config_secret_name
                key  = "oidc_client_secret"
              }
            }
          }
          env {
            name = "BETTER_AUTH_SECRET"
            value_from {
              secret_key_ref {
                name = module.thunderbolt_tls_vault.config_secret_name
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
            # Better Auth SSO validates the OIDC discovery URL (and every
            # endpoint resolved from it) against trustedOrigins; by default it
            # trusts only the app origin, so cross-origin IdP discovery fails
            # with `discovery_untrusted_origin`. Add the Zitadel issuer origin
            # (same host as OIDC_ISSUER) — Zitadel serves all OIDC endpoints on
            # that one host, so a single entry covers discovery/token/jwks/etc.
            name  = "TRUSTED_ORIGINS"
            value = "${local.thunderbolt_public_url},https://${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"
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
                name = module.thunderbolt_tls_vault.config_secret_name
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
                name = module.thunderbolt_tls_vault.config_secret_name
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
              secretProviderClass = module.thunderbolt_tls_vault.spc_name
            }
          }
        }
      }
    }
  }

  depends_on = [
    module.thunderbolt_tls_vault,
    kubernetes_deployment.thunderbolt_postgres,
    kubernetes_deployment.thunderbolt_powersync,
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

resource "kubernetes_deployment" "thunderbolt" {
  metadata {
    name      = "thunderbolt"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "thunderbolt"
      }
    }

    template {
      metadata {
        labels = {
          app = "thunderbolt"
        }
        annotations = {
          # Rolls the pod whenever the frontend build Job's name changes
          # (i.e. whenever any input file or the git ref changes → new image)
          # so `:latest` is actually re-pulled.
          "build-job" = module.thunderbolt_frontend_build.job_name
          # Rolls on outer TLS/proxy nginx config changes.
          "nginx-config-hash"                   = sha1(kubernetes_config_map.thunderbolt_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "thunderbolt-tls"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.thunderbolt.metadata[0].name

        # Pinned to artemis (Phase-4) — frontend colocated with backend.
        node_selector = { node = "artemis" }
        toleration {
          key      = "gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        image_pull_secrets {
          name = kubernetes_secret.thunderbolt_registry_pull_secret.metadata[0].name
        }

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "tls_crt"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Frontend SPA (nginx serving dist on :80)
        container {
          name  = "frontend"
          image = local.thunderbolt_frontend_image
          image_pull_policy = "Always"

          port {
            container_port = 80
            name           = "http"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }
        }

        # TLS-terminating nginx (path routing to backend / powersync / SPA)
        container {
          name  = "nginx"
          image = var.image_nginx
          image_pull_policy = "Always"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "thunderbolt-tls"
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
              cpu    = "300m"
              memory = "256Mi"
            }
          }
        }

        # Tailscale
        container {
          name  = "tailscale"
          image = var.image_tailscale
          image_pull_policy = "Always"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.thunderbolt_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.thunderbolt_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.thunderbolt_domain
          }
          env {
            name  = "TS_EXTRA_ARGS"
            value = "--login-server=https://${data.terraform_remote_state.homelab.outputs.headscale_server_fqdn}"
          }
          env {
            name  = "TS_TAILSCALED_EXTRA_ARGS"
            value = "--port=41641"
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
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.thunderbolt_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "thunderbolt-tls"
          secret {
            secret_name = module.thunderbolt_tls_vault.tls_secret_name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.thunderbolt_tls_vault.spc_name
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
    module.thunderbolt_tls_vault,
    kubernetes_deployment.thunderbolt_backend,
    module.thunderbolt_frontend_build,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "thunderbolt" {
  metadata {
    name      = "thunderbolt"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }
  spec {
    selector = {
      app = "thunderbolt"
    }
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
  }
}

# NetworkPolicies for the `thunderbolt` namespace.
#
# Hosts: thunderbolt-backend, thunderbolt-frontend (nginx), postgres,
# mongo, powersync. Most cross-pod traffic is intra-namespace
# (backend ↔ mongo, backend ↔ postgres, powersync ↔ postgres).
#
# thunderbolt-backend reaches `searxng.<hs>.<magic>`, `litellm.<hs>.<magic>`,
# and `<zitadel>.<hs>.<magic>` via host_aliases mapping the FQDNs to the
# corresponding Service ClusterIPs (egress-only Tailscale sidecar was
# never used here). The TCP 443 cross-ns egress allows below are
# load-bearing.

module "thunderbolt_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.thunderbolt.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

# Cross-ns egress: thunderbolt-backend → searxng:443. Mirror ingress lives
# in services/searxng-network.tf.
resource "kubernetes_network_policy" "thunderbolt_to_searxng" {
  metadata {
    name      = "thunderbolt-to-searxng"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  spec {
    pod_selector { match_labels = { app = "thunderbolt-backend" } }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.searxng.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "searxng" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

# Cross-ns egress: thunderbolt-backend → oidc (zitadel):443 for OIDC
# discovery + token exchange via Better Auth's genericOAuth plugin.
# Mirror ingress lives in services/zitadel-network.tf as
# oidc-from-thunderbolt.
resource "kubernetes_network_policy" "thunderbolt_to_oidc" {
  metadata {
    name      = "thunderbolt-to-oidc"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  spec {
    pod_selector { match_labels = { app = "thunderbolt-backend" } }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "oidc"
          }
        }
        pod_selector { match_labels = { app = "zitadel" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

# Cross-ns egress: thunderbolt-backend → litellm:443. Mirror ingress lives
# in services/litellm-network.tf.
resource "kubernetes_network_policy" "thunderbolt_to_litellm" {
  metadata {
    name      = "thunderbolt-to-litellm"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  spec {
    pod_selector { match_labels = { app = "thunderbolt-backend" } }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.litellm.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "litellm" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}
