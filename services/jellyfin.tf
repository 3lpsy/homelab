resource "kubernetes_namespace" "jellyfin" {
  metadata {
    name = "jellyfin"
  }
}

resource "kubernetes_service_account" "jellyfin" {
  metadata {
    name      = "jellyfin"
    namespace = kubernetes_namespace.jellyfin.metadata[0].name
  }
  automount_service_account_token = false
}

# Per-namespace dockerconfigjson Secret for pulling the custom Jellyfin
# image from the in-cluster registry. Mirrors services/homeassist.tf's
# `homeassist_registry_pull_secret`.
resource "kubernetes_secret" "jellyfin_registry_pull_secret" {
  metadata {
    name      = "registry-pull-secret"
    namespace = kubernetes_namespace.jellyfin.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${var.registry_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}" = {
          username = "internal"
          password = random_password.registry_user_passwords["internal"].result
          auth     = base64encode("internal:${random_password.registry_user_passwords["internal"].result}")
        }
      }
    })
  }
}

module "jellyfin_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "jellyfin"
  namespace            = kubernetes_namespace.jellyfin.metadata[0].name
  service_account_name = kubernetes_service_account.jellyfin.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.jellyfin_server_user
}

# Vault-stored creds:
#   - seed_admin_password — the hidden `_seed` Jellyfin admin used by the
#     seed Job to drive Jellyfin's HTTP API. Personal + partner accounts
#     are passwordless (OIDC + Quick Connect only), so this is the only
#     local password Jellyfin ever has.
#   - oidc_client_id / oidc_client_secret — Zitadel OIDC creds, consumed
#     by the seed Job which POSTs them to the SSO plugin's
#     /sso/OID/Add/zitadel endpoint. Main pod doesn't read these (the
#     plugin loads its config from /config/plugins/configurations/SSO-Auth.xml).
resource "random_password" "jellyfin_seed_admin" {
  length  = 48
  special = false
}

# Per-user random passwords for ADMIN Jellyfin users. Jellyfin 10.11+
# enforces a hard constraint that admin users cannot have empty
# passwords (UserManager.ChangePassword throws "Admin user passwords
# must not be empty"). The seeded human admin user (jim) is therefore
# given a Vault-stored random password by the seed Job. This password
# is functionally write-only — once the admin OIDC-logs-in for the
# first time, the SSO plugin pins their `AuthenticationProviderId` to
# the SSO plugin and password-form login stops working for them.
# Non-admin users stay passwordless via /Users/<id>/Password
# {ResetPassword: true}, which is allowed for non-admin users.
#
# `for_each` over the admin-users list (currently personal only) so
# adding a third admin in the future is one line. The map keys use
# the FULL Zitadel login_name form (`<user_name>@<magic_domain>`)
# because Zitadel's `preferred_username` claim emits this form, and
# the SSO plugin's username-match path keys off it. Seeding with
# the bare `<user_name>` would JIT-create a duplicate user on first
# OIDC login (verified empirically). Convention is documented in
# `feedback_zitadel_user_mapping_clarify` and
# `user_identity_convention` memories.
resource "random_password" "jellyfin_user_passwords" {
  for_each = toset([
    "${var.zitadel_personal_user.user_name}@${var.headscale_magic_domain}",
  ])
  length  = 48
  special = false
}

module "jellyfin_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "jellyfin"
  namespace            = kubernetes_namespace.jellyfin.metadata[0].name
  service_account_name = kubernetes_service_account.jellyfin.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = "${var.jellyfin_domain}.${local.magic_fqdn_suffix}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  config_secrets = merge(
    {
      seed_admin_password = random_password.jellyfin_seed_admin.result
      oidc_client_id      = zitadel_application_oidc.jellyfin.client_id
      oidc_client_secret  = zitadel_application_oidc.jellyfin.client_secret
    },
    {
      for u, p in random_password.jellyfin_user_passwords :
      "password_${u}" => p.result
    },
  )

  providers = { acme = acme }
}

resource "kubernetes_persistent_volume_claim" "jellyfin_config" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "jellyfin-config"
    namespace = kubernetes_namespace.jellyfin.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.jellyfin_config_size
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_persistent_volume_claim" "jellyfin_cache" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "jellyfin-cache"
    namespace = kubernetes_namespace.jellyfin.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.jellyfin_cache_size
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_persistent_volume_claim" "jellyfin_media" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "jellyfin-media"
    namespace = kubernetes_namespace.jellyfin.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.jellyfin_media_size
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_config_map" "jellyfin_nginx_config" {
  metadata {
    name      = "jellyfin-nginx-config"
    namespace = kubernetes_namespace.jellyfin.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/jellyfin.nginx.conf.tpl", {
      server_domain       = "${var.jellyfin_domain}.${local.magic_fqdn_suffix}"
      nginx_logging_block = local.nginx_logging_blocks["jellyfin"]
    })
  }
}

# Single-pod namespace. Config + cache live on PVCs; no DB, no shared cache.
# Outbound only needs kube-dns + the tailnet sidecar — netpol-baseline covers
# both. Tailscale traffic exits through the sidecar's NET_ADMIN-managed
# interface, not via cluster netpol.
module "jellyfin_netpol_baseline" {
  source = "../templates/netpol-baseline"

  namespace    = kubernetes_namespace.jellyfin.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

resource "kubernetes_deployment" "jellyfin" {
  metadata {
    name      = "jellyfin"
    namespace = kubernetes_namespace.jellyfin.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      # Single PVC RWO + a host_path GPU mount = no overlap allowed.
      type = "Recreate"
    }
    selector {
      match_labels = { app = "jellyfin" }
    }

    template {
      metadata {
        labels = { app = "jellyfin" }
        annotations = {
          "nginx-config-hash"                   = sha1(kubernetes_config_map.jellyfin_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = module.jellyfin_tls_vault.tls_secret_name
        }
      }

      spec {
        service_account_name = kubernetes_service_account.jellyfin.metadata[0].name

        image_pull_secrets {
          name = kubernetes_secret.jellyfin_registry_pull_secret.metadata[0].name
        }

        # Pin oidc.<magic> to Zitadel ClusterIP so the SSO plugin's
        # discovery + JWKS + token + userinfo calls go through the cluster
        # network (per `feedback_no_egress_only_ts_sidecars`). The
        # `jellyfin-to-oidc` NetworkPolicy below permits the actual
        # TCP/443 to the oidc namespace.
        host_aliases {
          ip        = data.terraform_remote_state.vault_conf.outputs.zitadel_cluster_ip
          hostnames = ["${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"]
        }

        # Pod-level supplementalGroups apply to every container in the pod.
        # The Jellyfin container is the only one that touches /dev/dri, but
        # adding render+video at pod level is the only place the K8s API
        # accepts these (containerd ignores container-scoped supp groups).
        # Values match the host's `getent group render video` (Fedora 41
        # defaults: render=105, video=39). Override via tfvars if the host
        # ever renumbers.
        security_context {
          supplemental_groups = [var.jellyfin_render_gid, var.jellyfin_video_gid]
        }

        # Jellyfin's official image runs as uid 1000:1000. PVCs land
        # root-owned on first bind; chown them so the main container can
        # write. Idempotent on subsequent rolls.
        init_container {
          name  = "fix-permissions"
          image = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            "chown -R 1000:1000 /config /cache"
          ]
          volume_mount {
            name       = "jellyfin-config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "jellyfin-cache"
            mount_path = "/cache"
          }
        }

        # Install the 9p4 SSO plugin into the PVC's plugins/ directory.
        # The custom image bakes the plugin files at /extras/plugins/
        # rather than /config/plugins/ because /config is a PVC mount
        # that would hide the image-baked files. Same pattern as
        # services/homeassist.tf:`install-auth-oidc`.
        # Always overwrites: a Dockerfile bump (new SSO_PLUGIN_VERSION)
        # propagates on next pod restart without manual cleanup.
        init_container {
          name  = "install-sso-plugin"
          image = local.jellyfin_image
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            <<-EOT
              set -e
              mkdir -p /config/plugins
              # Wipe stale SSO-Auth_* directories — only the version
              # baked into THIS image stays. Avoids ABI conflicts when
              # the plugin version is bumped.
              find /config/plugins -maxdepth 1 -type d -name 'SSO-Auth_*' -exec rm -rf {} +
              cp -a /extras/plugins/. /config/plugins/
              echo "SSO plugin installed:"
              ls /config/plugins/
            EOT
          ]
          volume_mount {
            name       = "jellyfin-config"
            mount_path = "/config"
          }
          security_context {
            run_as_user  = 1000
            run_as_group = 1000
          }
        }

        # Jellyfin
        container {
          name  = "jellyfin"
          image = local.jellyfin_image
          image_pull_policy = "Always"

          port {
            container_port = 8096
            name           = "http"
          }

          # Pin the API listener so the nginx upstream is stable.
          env {
            name  = "JELLYFIN_PublishedServerUrl"
            value = "https://${var.jellyfin_domain}.${local.magic_fqdn_suffix}"
          }

          volume_mount {
            name       = "jellyfin-config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "jellyfin-cache"
            mount_path = "/cache"
          }
          # Media library. Empty to start; populate by copying files into the
          # PVC's local-path dir on delphi. Add it as a Jellyfin library at
          # /media. RW so Jellyfin can write sidecar artwork/NFO if enabled.
          volume_mount {
            name       = "jellyfin-media"
            mount_path = "/media"
          }
          # AMD VAAPI: pass /dev/dri (renderD128 + card0) into the container.
          # Hardware accel is opt-in via the Jellyfin admin UI; this just makes
          # the device files available so the operator can flip the toggle.
          # Render + video GIDs are added at the pod-level securityContext.
          volume_mount {
            name       = "dri"
            mount_path = "/dev/dri"
          }

          resources {
            requests = { cpu = "200m", memory = "512Mi" }
            limits   = { cpu = "4000m", memory = "4Gi" }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8096
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8096
            }
            initial_delay_seconds = 20
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }

        # Jellyfin Volumes
        volume {
          name = "jellyfin-config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.jellyfin_config.metadata[0].name
          }
        }
        volume {
          name = "jellyfin-cache"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.jellyfin_cache.metadata[0].name
          }
        }
        volume {
          name = "jellyfin-media"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.jellyfin_media.metadata[0].name
          }
        }
        volume {
          name = "dri"
          host_path {
            path = "/dev/dri"
          }
        }

        # Nginx — TLS terminator, reverse-proxies localhost:8096.
        container {
          name  = "jellyfin-nginx"
          image = var.image_nginx
          image_pull_policy = "Always"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "jellyfin-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }
          # Mount the CSI volume here (read-only) so the SecretProviderClass
          # reconciles and the synced jellyfin-tls k8s secret materializes
          # for nginx to read.
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets-store"
            read_only  = true
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        # Nginx Volumes
        volume {
          name = "jellyfin-tls"
          secret { secret_name = module.jellyfin_tls_vault.tls_secret_name }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.jellyfin_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.jellyfin_tls_vault.spc_name
            }
          }
        }

        # Tailscale — joins the tailnet as `jellyfin` under media@.
        container {
          name  = "jellyfin-tailscale"
          image = var.image_tailscale
          image_pull_policy = "Always"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.jellyfin_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.jellyfin_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.jellyfin_domain
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
    module.jellyfin_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "jellyfin" {
  metadata {
    name      = "jellyfin"
    namespace = kubernetes_namespace.jellyfin.metadata[0].name
  }

  spec {
    selector = { app = "jellyfin" }
    type     = "ClusterIP"

    # 443 is the tailnet-fronted nginx port; 8096 is exposed for the
    # in-namespace seed Job (which talks plain HTTP to Jellyfin's app
    # listener directly, bypassing nginx + TLS).
    port {
      name        = "https"
      port        = 443
      target_port = 443
      protocol    = "TCP"
    }
    port {
      name        = "http"
      port        = 8096
      target_port = 8096
      protocol    = "TCP"
    }
  }
}

# ─── Zitadel project + OIDC application + per-user grants ────────────────────
#
# Per memory `feedback_zitadel_one_project_per_service`, each service gets
# its own project. The seed Job reconciles the SSO plugin's config (in
# /config/plugins/configurations/SSO-Auth.xml) with these values via
# POST /sso/OID/Add/zitadel — see data/jellyfin/seed.py reconcile_sso_plugin.
resource "zitadel_project" "jellyfin" {
  name   = "jellyfin"
  org_id = data.zitadel_organizations.homelab.ids[0]

  project_role_assertion = false
  project_role_check     = false
  # Only Zitadel users with an explicit `zitadel_user_grant` on this
  # project receive id_tokens. Required because the SSO plugin in
  # Jellyfin runs with `EnableAuthorization=false` (the role-based
  # admin/folder permission logic demotes-on-every-login when role
  # claims don't match AdminRoles); access control therefore lives
  # entirely upstream at Zitadel via this flag.
  has_project_check        = true
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"
}

resource "zitadel_application_oidc" "jellyfin" {
  name       = "Jellyfin"
  org_id     = data.zitadel_organizations.homelab.ids[0]
  project_id = zitadel_project.jellyfin.id

  # The 9p4 plugin advertises one of two redirect-URI shapes based on
  # its `NewPath` config flag. The seed Job (data/jellyfin/seed.py
  # desired_sso_config) sets `NewPath = true` so the plugin uses
  # `/sso/OID/redirect/<provider>` consistently. Register both forms
  # to insulate from a future plugin upgrade flipping the default,
  # since extra registered URIs are harmless.
  redirect_uris = [
    "https://${var.jellyfin_domain}.${local.magic_fqdn_suffix}/sso/OID/redirect/zitadel",
    "https://${var.jellyfin_domain}.${local.magic_fqdn_suffix}/sso/OID/r/zitadel",
  ]
  post_logout_redirect_uris = [
    "https://${var.jellyfin_domain}.${local.magic_fqdn_suffix}/web/index.html",
  ]

  response_types   = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types      = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"]
  app_type         = "OIDC_APP_TYPE_WEB"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_BASIC"
  dev_mode         = false
}

# Personal user is admin in Jellyfin (seed Job sets IsAdministrator=true
# on this user's local account, identified by the Zitadel preferred_username).
resource "zitadel_user_grant" "jellyfin_personal_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.personal.id
  project_id = zitadel_project.jellyfin.id
  role_keys  = []
}

# Partner user is a regular Jellyfin user.
resource "zitadel_user_grant" "jellyfin_partner_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.partner.id
  project_id = zitadel_project.jellyfin.id
  role_keys  = []
}

# Cross-ns egress: jellyfin → oidc:443 for OIDC discovery + JWKS + token +
# userinfo. Mirror ingress lives in services/zitadel-network.tf as
# oidc-from-jellyfin. Pod-scoped per memory feedback_netpol_least_privilege;
# covers both the main Deployment (`app = jellyfin`) and the seed Job
# (`app = jellyfin-seed`). The seed pod uses a distinct label so the
# jellyfin Service selector does not include it as an endpoint.
resource "kubernetes_network_policy" "jellyfin_to_oidc" {
  metadata {
    name      = "jellyfin-to-oidc"
    namespace = kubernetes_namespace.jellyfin.metadata[0].name
  }
  spec {
    pod_selector {
      match_expressions {
        key      = "app"
        operator = "In"
        values   = ["jellyfin", "jellyfin-seed"]
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
