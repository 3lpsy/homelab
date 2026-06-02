resource "kubernetes_namespace" "audiobookshelf" {
  metadata {
    name = "audiobookshelf"
  }
}

resource "kubernetes_service_account" "audiobookshelf" {
  metadata {
    name      = "audiobookshelf"
    namespace = kubernetes_namespace.audiobookshelf.metadata[0].name
  }
  automount_service_account_token = false
}

# Per-user random_password. Add a name to var.audiobookshelf_users to provision
# another account; remove + apply to retire one. The first entry is the root
# admin and is also used for the POST /init bootstrap.
resource "random_password" "audiobookshelf_user_passwords" {
  for_each = toset(var.audiobookshelf_users)
  length   = 32
  special  = false
}

# Pin the JWT signing key so a wipe-and-restore of the config PVC keeps
# already-issued client tokens valid. ABS auto-generates one if absent.
resource "random_password" "audiobookshelf_jwt_secret" {
  length  = 64
  special = false
}

module "audiobookshelf_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "audiobookshelf"
  namespace            = kubernetes_namespace.audiobookshelf.metadata[0].name
  service_account_name = kubernetes_service_account.audiobookshelf.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.podcast_server_user
}

module "audiobookshelf_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "audiobookshelf"
  namespace            = kubernetes_namespace.audiobookshelf.metadata[0].name
  service_account_name = kubernetes_service_account.audiobookshelf.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = "${var.audiobookshelf_domain}.${local.magic_fqdn_suffix}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  config_secrets = merge(
    {
      jwt_secret_key = random_password.audiobookshelf_jwt_secret.result
      # Zitadel OIDC client creds — consumed by the seed Job's reconcile_oidc
      # step (PATCH /api/auth-settings). Not surfaced as env vars on the ABS
      # container itself; ABS reads its OIDC config from SQLite which the seed
      # script keeps in sync with these values.
      oidc_client_id     = zitadel_application_oidc.audiobookshelf.client_id
      oidc_client_secret = zitadel_application_oidc.audiobookshelf.client_secret
    },
    {
      for u in var.audiobookshelf_users :
      "password_${u}" => random_password.audiobookshelf_user_passwords[u].result
    },
  )

  providers = { acme = acme }
}

resource "kubernetes_persistent_volume_claim" "audiobookshelf_config" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "audiobookshelf-config"
    namespace = kubernetes_namespace.audiobookshelf.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.audiobookshelf_config_size
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_persistent_volume_claim" "audiobookshelf_metadata" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "audiobookshelf-metadata"
    namespace = kubernetes_namespace.audiobookshelf.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.audiobookshelf_metadata_size
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_persistent_volume_claim" "audiobookshelf_podcasts" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "audiobookshelf-podcasts"
    namespace = kubernetes_namespace.audiobookshelf.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.audiobookshelf_podcasts_size
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_config_map" "audiobookshelf_nginx_config" {
  metadata {
    name      = "audiobookshelf-nginx-config"
    namespace = kubernetes_namespace.audiobookshelf.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/audiobookshelf.nginx.conf.tpl", {
      server_domain       = "${var.audiobookshelf_domain}.${local.magic_fqdn_suffix}"
      nginx_logging_block = local.nginx_logging_blocks["audiobookshelf"]
    })
  }
}

# Default-deny baseline — intra-ns traffic (job → server), DNS, K8s API,
# and outbound internet (tailscale sidecar + iTunes search + RSS fetches).
module "audiobookshelf_netpol_baseline" {
  source = "../templates/netpol-baseline"

  namespace    = kubernetes_namespace.audiobookshelf.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

resource "kubernetes_deployment" "audiobookshelf" {
  metadata {
    name      = "audiobookshelf"
    namespace = kubernetes_namespace.audiobookshelf.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "audiobookshelf" }
    }

    template {
      metadata {
        labels = { app = "audiobookshelf" }
        annotations = {
          "nginx-config-hash"                   = sha1(kubernetes_config_map.audiobookshelf_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "${module.audiobookshelf_tls_vault.config_secret_name},${module.audiobookshelf_tls_vault.tls_secret_name}"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.audiobookshelf.metadata[0].name

        # Pin oidc.<tailnet> to the in-cluster Zitadel ClusterIP. ABS verifies
        # OIDC tokens by fetching JWKS + userinfo on every login; SNI carries
        # the FQDN so the LE cert validates against the ClusterIP, no Tailscale
        # egress sidecar needed. Mirrors the homeassist/rustical pattern.
        host_aliases {
          ip        = data.terraform_remote_state.vault_conf.outputs.zitadel_cluster_ip
          hostnames = ["${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"]
        }

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "password_${var.audiobookshelf_users[0]}"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # ABS image runs as uid 1000 by default; ensure all three PVCs are
        # writable to that uid on first apply (idempotent on subsequent rolls).
        init_container {
          name  = "fix-permissions"
          image = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            "chown -R 1000:1000 /config /metadata /podcasts"
          ]
          volume_mount {
            name       = "audiobookshelf-config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "audiobookshelf-metadata"
            mount_path = "/metadata"
          }
          volume_mount {
            name       = "audiobookshelf-podcasts"
            mount_path = "/podcasts"
          }
        }

        # Audiobookshelf
        container {
          name  = "audiobookshelf"
          image = var.image_audiobookshelf
          image_pull_policy = "Always"

          port {
            container_port = 80
            name           = "http"
          }

          env {
            name  = "PORT"
            value = "80"
          }
          env {
            name  = "CONFIG_PATH"
            value = "/config"
          }
          env {
            name  = "METADATA_PATH"
            value = "/metadata"
          }
          env {
            name  = "TZ"
            value = "America/Chicago"
          }
          # Default V8 max heap is ~512MB on Node 20, regardless of cgroup
          # limit. Big OPML imports + 130 RSS parses concurrently push past
          # that and OOM the process. Pin heap to 1.5GB; pair with the 2Gi
          # cgroup limit below so Node has headroom.
          env {
            name  = "NODE_OPTIONS"
            value = "--max-old-space-size=1536"
          }
          # Pin the JWT signing key so DB restores keep tokens valid.
          env {
            name = "JWT_SECRET_KEY"
            value_from {
              secret_key_ref {
                name = module.audiobookshelf_tls_vault.config_secret_name
                key  = "jwt_secret_key"
              }
            }
          }

          volume_mount {
            name       = "audiobookshelf-config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "audiobookshelf-metadata"
            mount_path = "/metadata"
          }
          volume_mount {
            name       = "audiobookshelf-podcasts"
            mount_path = "/podcasts"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "100m", memory = "512Mi" }
            limits   = { cpu = "1000m", memory = "2Gi" }
          }

          # ABS is single-threaded Node — under bursts of work (RSS feed
          # fetches, library scans, big OPML imports) the event loop can
          # block for several seconds. Default 1s timeout × 3 failures
          # marked the pod NotReady mid-seed-Job run, kube-proxy stripped
          # the endpoint, and follow-up calls saw [Errno 111] until probes
          # caught up. Allow longer timeouts and more consecutive misses.
          liveness_probe {
            http_get {
              path = "/healthcheck"
              port = 80
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 10
            failure_threshold     = 5
          }

          readiness_probe {
            http_get {
              path = "/healthcheck"
              port = 80
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 6
          }
        }

        # Audiobookshelf Volumes
        volume {
          name = "audiobookshelf-config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.audiobookshelf_config.metadata[0].name
          }
        }
        volume {
          name = "audiobookshelf-metadata"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.audiobookshelf_metadata.metadata[0].name
          }
        }
        volume {
          name = "audiobookshelf-podcasts"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.audiobookshelf_podcasts.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.audiobookshelf_tls_vault.spc_name
            }
          }
        }

        # Nginx
        container {
          name  = "audiobookshelf-nginx"
          image = var.image_nginx
          image_pull_policy = "Always"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "audiobookshelf-tls"
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

        # Nginx Volumes
        volume {
          name = "audiobookshelf-tls"
          secret { secret_name = module.audiobookshelf_tls_vault.tls_secret_name }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.audiobookshelf_nginx_config.metadata[0].name
          }
        }

        # Tailscale
        container {
          name  = "audiobookshelf-tailscale"
          image = var.image_tailscale
          image_pull_policy = "Always"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.audiobookshelf_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.audiobookshelf_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.audiobookshelf_domain
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

        # Tailscale Volumes
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
    module.audiobookshelf_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

# In-cluster Service so the seed Job can reach ABS without going through
# the tailscale sidecar.
resource "kubernetes_service" "audiobookshelf" {
  metadata {
    name      = "audiobookshelf"
    namespace = kubernetes_namespace.audiobookshelf.metadata[0].name
  }

  spec {
    selector = { app = "audiobookshelf" }
    type     = "ClusterIP"

    port {
      name        = "http"
      port        = 80
      target_port = 80
      protocol    = "TCP"
    }
  }
}

# ─── Zitadel project + OIDC application + per-user grant ─────────────────────
#
# Per memory `feedback_zitadel_one_project_per_service`, each service gets its
# own project. The seed Job reconciles ABS's SQLite server-settings row with
# these values via PATCH /api/auth-settings (see data/audiobookshelf/seed.py
# `reconcile_oidc`).
resource "zitadel_project" "audiobookshelf" {
  name   = "audiobookshelf"
  org_id = data.zitadel_organizations.homelab.ids[0]

  project_role_assertion   = false
  project_role_check       = false
  has_project_check        = false
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"
}

resource "zitadel_application_oidc" "audiobookshelf" {
  name       = "Audiobookshelf"
  org_id     = data.zitadel_organizations.homelab.ids[0]
  project_id = zitadel_project.audiobookshelf.id

  # Web callback + mobile-redirect (proxy used by the official ABS apps when
  # the native scheme can't be invoked) + native schemes. The mobile schemes
  # are also written into ABS's own `authOpenIDMobileRedirectURIs` allow-list
  # by the seed reconcile.
  redirect_uris = [
    "https://${var.audiobookshelf_domain}.${local.magic_fqdn_suffix}/auth/openid/callback",
    "https://${var.audiobookshelf_domain}.${local.magic_fqdn_suffix}/auth/openid/mobile-redirect",
    "audiobookshelf://oauth",  # official ABS Android/iOS app
    "shelfplayer://callback",  # ShelfPlayer iOS client (rasmuslos/ShelfPlayer)
  ]
  # ABS defaults `ROUTER_BASE_PATH` to the literal string `/audiobookshelf`
  # (see advplyr/audiobookshelf index.js). The OIDC logout flow builds the
  # post_logout_redirect_uri as `${host}${RouterBasePath}/login`, so we have
  # to register the prefixed form. Forcing the env var to empty would also
  # work but breaks the Nuxt frontend's asset paths (router.base == "" is
  # undocumented). The auth-callback URI is unaffected because that path is
  # governed by the separate `authOpenIDSubfolderForRedirectURLs` setting,
  # which the seed.py reconcile pins to "".
  post_logout_redirect_uris = [
    "https://${var.audiobookshelf_domain}.${local.magic_fqdn_suffix}/audiobookshelf/login",
    "https://${var.audiobookshelf_domain}.${local.magic_fqdn_suffix}/login",
  ]

  response_types   = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types      = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"]
  app_type         = "OIDC_APP_TYPE_WEB"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_BASIC"
  dev_mode         = false
}

# Grant for the personal Zitadel user. Mirrors homeassist/rustical/grafana —
# pre-positioned for if/when project_role_check gets flipped on. With
# autoRegister=false in ABS's auth-settings, no other Zitadel user can mint a
# local ABS account even without project-level enforcement.
resource "zitadel_user_grant" "audiobookshelf_personal_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.personal.id
  project_id = zitadel_project.audiobookshelf.id
  role_keys  = []
}

# Cross-ns egress: audiobookshelf → oidc:443 for token exchange + JWKS fetch.
# Mirror ingress lives in services/zitadel-network.tf as oidc-from-audiobookshelf.
# Pod-scoped per memory feedback_netpol_least_privilege; covers both the main
# Deployment (`app = audiobookshelf`) and the seed Job (`app = audiobookshelf-seed`).
# The seed pod uses a distinct label so the audiobookshelf Service selector does
# not include it as an endpoint.
resource "kubernetes_network_policy" "audiobookshelf_to_oidc" {
  metadata {
    name      = "audiobookshelf-to-oidc"
    namespace = kubernetes_namespace.audiobookshelf.metadata[0].name
  }
  spec {
    pod_selector {
      match_expressions {
        key      = "app"
        operator = "In"
        values   = ["audiobookshelf", "audiobookshelf-seed"]
      }
    }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "oidc"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}
