# halogen — self-hosted podcast manager (the user's own app, dogfooded here).
#
# Single-file service (CLAUDE.md "Single-file exception"). Lives in its own
# `podcasts` namespace, fronted by nginx (TLS) + a tailscale ingress sidecar,
# reachable only over the tailnet at `pod.<magic>`. audiobookshelf already owns
# `podcast.<magic>` and the same `podcast_server_user` tailnet identity — halogen
# reuses that user but a distinct hostname, so no homelab/ changes are needed.
#
# Image `halogen:dev` is built + pushed to the in-cluster registry by git-runner;
# there is NO BuildKit job here. imagePullPolicy=Always pulls the freshest :dev
# on every roll. Registry pull creds are synthesized from Vault (the shared
# `data.vault_kv_secret_v2.registry_config` + `local.registry_fqdn` /
# `local.registry_internal_password` declared in services/otel-collector.tf).
#
# halogen seeds the admin user and imports the OPML natively on boot (env vars),
# so unlike audiobookshelf there is no seed Job. No in-cluster Service either —
# nothing in the cluster consumes it; all access is over tailscale.

locals {
  halogen_image = "${local.thunderbolt_registry}/halogen:dev"

  # OPML preseed: prefer the user's gitignored list, fall back to the checked-in
  # example so a clean clone still applies. halogen import is idempotent (skips
  # feed URLs already present), so re-running on every boot is safe.
  podcasts_opml_user    = "${path.module}/../${var.podcasts_opml_path}"
  podcasts_opml_example = "${path.module}/../data/audiobookshelf/podcasts.example.opml"
  podcasts_opml_blob = fileexists(local.podcasts_opml_user) ? file(local.podcasts_opml_user) : (
    fileexists(local.podcasts_opml_example) ? file(local.podcasts_opml_example) : ""
  )
}

resource "kubernetes_namespace" "podcasts" {
  metadata {
    name = "podcasts"
  }
}

resource "kubernetes_service_account" "podcasts" {
  metadata {
    name      = "podcasts"
    namespace = kubernetes_namespace.podcasts.metadata[0].name
  }
  automount_service_account_token = false
}

# Admin password halogen sets for HALOGEN_ADMIN_USERNAME on first boot. Vault is
# the source of truth (feedback_vault_app_passwords); rotate with
# `terraform apply -replace=random_password.podcasts_admin`.
resource "random_password" "podcasts_admin" {
  length  = 32
  special = false
}

# JWT signing secret. HALOGEN_AUTH_TOKEN_SECRET is REQUIRED — the server refuses
# to start without it. Pin it so already-issued client sessions survive a pod
# restart / DB restore (halogen would otherwise have no stable default).
resource "random_password" "podcasts_auth_token" {
  length  = 64
  special = false
}

module "podcasts_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "podcasts"
  namespace            = kubernetes_namespace.podcasts.metadata[0].name
  service_account_name = kubernetes_service_account.podcasts.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.podcast_server_user
}

module "podcasts_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "podcasts"
  namespace            = kubernetes_namespace.podcasts.metadata[0].name
  service_account_name = kubernetes_service_account.podcasts.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = "${var.podcasts_domain}.${local.magic_fqdn_suffix}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  config_secrets = {
    admin_password    = random_password.podcasts_admin.result
    auth_token_secret = random_password.podcasts_auth_token.result
  }

  providers = { acme = acme }
}

# Single PVC at /data: halogen.db (sqlite) + /data/media (downloaded episodes).
resource "kubernetes_persistent_volume_claim" "podcasts_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "podcasts-data"
    namespace = kubernetes_namespace.podcasts.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.podcasts_storage_size
      }
    }
  }
  wait_until_bound = false
}

# Pull creds for `halogen:dev` from the in-cluster registry. Mirrors
# services/otel-collector.tf's registry-pull-secret (reuses the shared
# registry_config Vault read + registry_fqdn / registry_internal_password locals).
resource "kubernetes_secret" "podcasts_registry_pull_secret" {
  metadata {
    name      = "registry-pull-secret"
    namespace = kubernetes_namespace.podcasts.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${local.registry_fqdn}" = {
          username = "internal"
          password = local.registry_internal_password
          auth     = base64encode("internal:${local.registry_internal_password}")
        }
      }
    })
  }
}

resource "kubernetes_config_map" "podcasts_nginx_config" {
  metadata {
    name      = "podcasts-nginx-config"
    namespace = kubernetes_namespace.podcasts.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/podcasts.nginx.conf.tpl", {
      server_domain       = "${var.podcasts_domain}.${local.magic_fqdn_suffix}"
      nginx_logging_block = local.nginx_logging_blocks["podcasts"]
    })
  }
}

# OPML mounted read-only; halogen reads it on boot (HALOGEN_OPML_FILE).
resource "kubernetes_config_map" "podcasts_opml" {
  metadata {
    name      = "podcasts-opml"
    namespace = kubernetes_namespace.podcasts.metadata[0].name
  }
  data = {
    "podcasts.opml" = local.podcasts_opml_blob
  }
}

# Default-deny baseline — intra-ns, DNS, K8s API (TS_KUBE_SECRET state), and
# outbound internet (tailscale sidecar DERP + RSS feed fetches + episode
# downloads). No cross-ns allows needed: halogen has no OIDC and no consumers.
module "podcasts_netpol_baseline" {
  source = "../templates/netpol-baseline"

  namespace    = kubernetes_namespace.podcasts.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

resource "kubernetes_deployment" "podcasts" {
  metadata {
    name      = "podcasts"
    namespace = kubernetes_namespace.podcasts.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "podcasts" }
    }

    template {
      metadata {
        labels = { app = "podcasts" }
        annotations = {
          "nginx-config-hash"                   = sha1(kubernetes_config_map.podcasts_nginx_config.data["nginx.conf"])
          "opml-hash"                           = sha1(kubernetes_config_map.podcasts_opml.data["podcasts.opml"])
          "secret.reloader.stakater.com/reload" = "${module.podcasts_tls_vault.config_secret_name},${module.podcasts_tls_vault.tls_secret_name}"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.podcasts.metadata[0].name

        image_pull_secrets {
          name = kubernetes_secret.podcasts_registry_pull_secret.metadata[0].name
        }

        # Gate on the Vault-synced admin password landing before halogen starts.
        init_container {
          name              = "wait-for-secrets"
          image             = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "admin_password"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # halogen image runs as uid 10001; make the PVC writable to it on first
        # apply (idempotent on later rolls).
        init_container {
          name              = "fix-permissions"
          image             = var.image_busybox
          image_pull_policy = "Always"
          command           = ["sh", "-c", "chown -R 10001:10001 /data"]
          volume_mount {
            name       = "podcasts-data"
            mount_path = "/data"
          }
        }

        # halogen
        container {
          name              = "podcasts"
          image             = local.halogen_image
          image_pull_policy = "Always"

          port {
            container_port = 8080
            name           = "http"
          }

          # Bind all interfaces (Dockerfile default is 0.0.0.0, set explicitly).
          env {
            name  = "HALOGEN_LISTEN_ADDRESS"
            value = "0.0.0.0"
          }
          env {
            name  = "HALOGEN_LISTEN_PORT"
            value = "8080"
          }
          env {
            name  = "HALOGEN_DB_PATH"
            value = "/data/halogen.db"
          }
          env {
            name  = "HALOGEN_MEDIA_ROOT"
            value = "/data/media"
          }
          env {
            name  = "HALOGEN_LOG_LEVEL"
            value = var.podcasts_log_level
          }
          env {
            name  = "TZ"
            value = "America/Chicago"
          }

          # ── Admin seed (first boot only; idempotent once a user exists) ──
          env {
            name  = "HALOGEN_ADMIN_USERNAME"
            value = var.podcasts_admin_username
          }
          env {
            name = "HALOGEN_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.podcasts_tls_vault.config_secret_name
                key  = "admin_password"
              }
            }
          }

          # ── Stable JWT signing secret (required) ──
          env {
            name = "HALOGEN_AUTH_TOKEN_SECRET"
            value_from {
              secret_key_ref {
                name = module.podcasts_tls_vault.config_secret_name
                key  = "auth_token_secret"
              }
            }
          }

          # ── OPML import on boot ──
          env {
            name  = "HALOGEN_OPML_FILE"
            value = "/etc/halogen/podcasts.opml"
          }

          # ── Subscription / polling tunables ──
          env {
            name  = "HALOGEN_SUBSCRIPTION_SYNC_ON_START"
            value = tostring(var.podcasts_sync_on_start)
          }
          env {
            name  = "HALOGEN_SUBSCRIPTION_FALLBACK_POLL_INTERVAL"
            value = tostring(var.podcasts_fallback_poll_interval_seconds)
          }
          env {
            name  = "HALOGEN_SUBSCRIPTION_FALLBACK_MAX_EPISODES"
            value = tostring(var.podcasts_fallback_max_episodes)
          }
          env {
            name  = "HALOGEN_SUBSCRIPTION_MAX_CONCURRENT_DOWNLOADS"
            value = tostring(var.podcasts_max_concurrent_downloads)
          }

          volume_mount {
            name       = "podcasts-data"
            mount_path = "/data"
          }
          volume_mount {
            name       = "podcasts-opml"
            mount_path = "/etc/halogen"
            read_only  = true
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "1000m", memory = "1Gi" }
          }

          # halogen has no /health; /polling/status returns 200 with the
          # polling-service state and needs no auth.
          liveness_probe {
            http_get {
              path = "/polling/status"
              port = 8080
            }
            initial_delay_seconds = 20
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }
          readiness_probe {
            http_get {
              path = "/polling/status"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 6
          }
        }

        # Nginx (TLS termination)
        container {
          name              = "podcasts-nginx"
          image             = var.image_nginx
          image_pull_policy = "Always"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "podcasts-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        # Tailscale ingress sidecar — advertises the pod to the tailnet as
        # `pod.<magic>`; inbound tailnet traffic hits nginx on :443.
        container {
          name              = "podcasts-tailscale"
          image             = var.image_tailscale
          image_pull_policy = "Always"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.podcasts_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.podcasts_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.podcasts_domain
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
            requests = { cpu = "20m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "256Mi" }
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

        # Volumes
        volume {
          name = "podcasts-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.podcasts_data.metadata[0].name
          }
        }
        volume {
          name = "podcasts-opml"
          config_map {
            name = kubernetes_config_map.podcasts_opml.metadata[0].name
          }
        }
        volume {
          name = "podcasts-tls"
          secret { secret_name = module.podcasts_tls_vault.tls_secret_name }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.podcasts_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.podcasts_tls_vault.spc_name
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
    module.podcasts_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}
