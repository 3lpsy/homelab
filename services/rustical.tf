# Rustical CalDAV/CardDAV server. Side-by-side with Radicale during the
# migration window. Rustical has native OIDC + Nextcloud-flow app passwords
# so DAV clients (Thunderbird, iPhone) get revocable per-device tokens
# instead of a single shared basic-auth password. No oauth2-proxy needed.
#
# Headscale tailnet user is the existing `calendar_server_user` (same as
# Radicale) so the rcal.<tailnet> hostname falls under the same ACL group
# as cal.<tailnet>. Keeping Radicale running unchanged in parallel.
#
# Storage: a single SQLite DB at /var/lib/rustical/. Migration of existing
# Radicale collections (filesystem ICS/VCF under /var/lib/radicale/...)
# into Rustical is a separate step done after both servers are up; not
# part of this initial deployment.

resource "kubernetes_namespace" "rustical" {
  metadata {
    name = "rustical"
  }
}

resource "kubernetes_service_account" "rustical" {
  metadata {
    name      = "rustical"
    namespace = kubernetes_namespace.rustical.metadata[0].name
  }
  automount_service_account_token = false
}

# ─── Tailnet ingress ──────────────────────────────────────────────────────────
module "rustical_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "rustical"
  namespace            = kubernetes_namespace.rustical.metadata[0].name
  service_account_name = kubernetes_service_account.rustical.metadata[0].name
  # Same tailnet user as Radicale — calendar role, single user owns both.
  tailnet_user_id = data.terraform_remote_state.homelab.outputs.tailnet_user_map.calendar_server_user
}

# ─── Zitadel project + OIDC application + per-user grant ─────────────────────
#
# Dedicated zitadel_project per service (NOT the shared zitadel_project.homelab).
# Per memory `feedback_zitadel_one_project_per_service.md`: a shared project
# leaks every app's client_id into every other app's id_token aud claim, which
# strict OIDC clients (rustical's openidconnect-rs) reject.
resource "zitadel_project" "rustical" {
  name   = "rustical"
  org_id = data.zitadel_organizations.homelab.ids[0]

  # No project-level role gating — authorization is per-user via user_grant
  # below. Flip to true once we want Zitadel to enforce that the user must
  # have at least one role on the project before login completes.
  project_role_assertion   = false
  project_role_check       = false
  has_project_check        = false
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"
}

resource "zitadel_application_oidc" "rustical" {
  name       = "Rustical"
  org_id     = data.zitadel_organizations.homelab.ids[0]
  project_id = zitadel_project.rustical.id

  redirect_uris             = ["https://${var.rustical_domain}.${local.magic_fqdn_suffix}/frontend/login/oidc/callback"]
  post_logout_redirect_uris = ["https://${var.rustical_domain}.${local.magic_fqdn_suffix}/frontend/login"]

  response_types   = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types      = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"]
  app_type         = "OIDC_APP_TYPE_WEB"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_BASIC"
  dev_mode         = false
}

# Explicit grant: only `jim` can sign in. Per the project memory
# `project_grafana_oidc_authz_pending.md` we don't repeat Grafana's
# loose any-Zitadel-user pattern in new services — bake authz in from
# day one.
#
# project_role_check is currently false on the rustical project, so this
# grant is a no-op for authorization enforcement today. Recorded here so
# the grant exists when we later flip project_role_check=true and start
# enforcing per-user access.
resource "zitadel_user_grant" "rustical_personal_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.personal.id
  project_id = zitadel_project.rustical.id
  role_keys  = []
}

resource "zitadel_user_grant" "rustical_partner_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.partner.id
  project_id = zitadel_project.rustical.id
  role_keys  = []
}

# ─── TLS cert + Vault KV (OIDC client creds) ──────────────────────────────────
module "rustical_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "rustical"
  namespace            = kubernetes_namespace.rustical.metadata[0].name
  service_account_name = kubernetes_service_account.rustical.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = "${var.rustical_domain}.${local.magic_fqdn_suffix}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  config_secrets = {
    oidc_client_id     = zitadel_application_oidc.rustical.client_id
    oidc_client_secret = zitadel_application_oidc.rustical.client_secret
  }

  providers = { acme = acme }
}

# ─── PVC ──────────────────────────────────────────────────────────────────────
resource "kubernetes_persistent_volume_claim" "rustical_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "rustical-data"
    namespace = kubernetes_namespace.rustical.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
  wait_until_bound = false
}

# ─── ConfigMap (nginx) ────────────────────────────────────────────────────────
resource "kubernetes_config_map" "rustical_nginx_config" {
  metadata {
    name      = "rustical-nginx-config"
    namespace = kubernetes_namespace.rustical.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/rustical.nginx.conf.tpl", {
      server_domain       = "${var.rustical_domain}.${local.magic_fqdn_suffix}"
      nginx_logging_block = local.nginx_logging_blocks["rustical"]
    })
  }
}

# ─── ConfigMap (default-calendar seed script) ─────────────────────────────────
# Idempotent SQLite-level seeder run as an init container. Creates the two
# user principals plus a shared group principal, makes both users members
# of the group, and creates each user's "Personal" calendar plus a single
# group-owned shared calendar. INSERT OR IGNORE everywhere so re-running
# on every pod restart is a no-op. See data/scripts/rustical-seed.py for
# the rationale behind the group-ownership sharing model.
resource "kubernetes_config_map" "rustical_seed_script" {
  metadata {
    name      = "rustical-seed-script"
    namespace = kubernetes_namespace.rustical.metadata[0].name
  }
  data = {
    "rustical-seed.py" = file("${path.module}/../data/scripts/rustical-seed.py")
  }
}

# ─── NetworkPolicies ──────────────────────────────────────────────────────────
module "rustical_netpol_baseline" {
  source = "../templates/netpol-baseline"

  namespace    = kubernetes_namespace.rustical.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

# Cross-ns egress: rustical → oidc:443 (auth-code dance with Zitadel).
# Pod-scoped to app=rustical per memory feedback_netpol_least_privilege.
# Mirror ingress lives in services/zitadel-network.tf as oidc-from-rustical.
resource "kubernetes_network_policy" "rustical_to_oidc" {
  metadata {
    name      = "rustical-to-oidc"
    namespace = kubernetes_namespace.rustical.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = { app = "rustical" }
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

# ─── Deployment ───────────────────────────────────────────────────────────────
resource "kubernetes_deployment" "rustical" {
  metadata {
    name      = "rustical"
    namespace = kubernetes_namespace.rustical.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "rustical" }
    }

    template {
      metadata {
        labels = { app = "rustical" }
        annotations = {
          "nginx-config-hash"                   = sha1(kubernetes_config_map.rustical_nginx_config.data["nginx.conf"])
          "seed-script-hash"                    = sha1(kubernetes_config_map.rustical_seed_script.data["rustical-seed.py"])
          "secret.reloader.stakater.com/reload" = "${module.rustical_tls_vault.config_secret_name},${module.rustical_tls_vault.tls_secret_name}"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.rustical.metadata[0].name

        # Wait for the OIDC client_id/secret + cert to land before booting.
        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "oidc_client_id"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Apply rustical's sqlx migrations against the PVC before the seed
        # init runs. `rustical principals list` calls get_data_stores(true,
        # ...) which triggers migrations as a side effect. On a fresh PVC
        # this creates the schema; afterwards it's a no-op. Config comes
        # from the image's baked-in env (RUSTICAL_DATA_STORE__SQLITE__DB_URL
        # = /var/lib/rustical/db.sqlite3) plus figment skipping the missing
        # TOML — no OIDC config required for this CLI path.
        init_container {
          name    = "migrate-db"
          image   = var.image_rustical
          image_pull_policy = "Always"
          command = ["/usr/local/bin/rustical", "principals", "list"]
          volume_mount {
            name       = "rustical-data"
            mount_path = "/var/lib/rustical"
          }
        }

        # Seed the two user principals, the shared group principal, the
        # group memberships, and the three default calendars (one per user
        # + one group-owned shared). All writes are PK-keyed INSERT OR
        # IGNORE so this is safe on every pod start. Group-ownership is
        # rustical's only sharing model — RFC 6638 share invites are not
        # implemented upstream.
        init_container {
          name    = "seed-defaults"
          image   = var.python_base_image
          image_pull_policy = "Always"
          command = ["uv", "run", "--no-project", "/seed/rustical-seed.py"]

          env {
            name  = "RUSTICAL_DB_PATH"
            value = "/var/lib/rustical/db.sqlite3"
          }
          # Match rustical's principal id as JIT-provisioned via OIDC. With
          # RUSTICAL_OIDC__CLAIM_USERID=preferred_username and Zitadel's
          # default policy (user_login_must_be_domain), preferred_username
          # is the loginname `<user_name>@<org-primary-domain>` — and per
          # services/zitadel-org-domain.tf the primary is the magic domain.
          # Bare user_name would create duplicate principals next to the
          # existing OIDC-created ones.
          env {
            name  = "SEED_PERSONAL_USER"
            value = "${var.zitadel_personal_user.user_name}@${var.headscale_magic_domain}"
          }
          env {
            name  = "SEED_PARTNER_USER"
            value = "${var.zitadel_partner_user.user_name}@${var.headscale_magic_domain}"
          }
          env {
            name  = "SEED_GROUP_ID"
            value = "household"
          }
          env {
            name  = "SEED_GROUP_DISPLAYNAME"
            value = "Household"
          }
          env {
            name  = "SEED_PERSONAL_CAL_ID"
            value = "personal"
          }
          env {
            name  = "SEED_PERSONAL_CAL_NAME"
            value = "Personal"
          }
          env {
            name  = "SEED_SHARED_CAL_ID"
            value = "taracal"
          }
          env {
            name  = "SEED_SHARED_CAL_NAME"
            value = "TaraCal"
          }

          volume_mount {
            name       = "rustical-data"
            mount_path = "/var/lib/rustical"
          }
          volume_mount {
            name       = "seed-script"
            mount_path = "/seed"
            read_only  = true
          }

          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "100m", memory = "64Mi" }
          }
        }

        # Pin oidc.<tailnet> to the Zitadel ClusterIP for SNI/cert validation
        # without a Tailscale egress sidecar.
        host_aliases {
          ip        = data.terraform_remote_state.vault_conf.outputs.zitadel_cluster_ip
          hostnames = ["${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"]
        }

        # ─── Rustical ─────────────────────────────────────────────────────────
        container {
          name  = "rustical"
          image = var.image_rustical
          image_pull_policy = "Always"

          port {
            container_port = 4000
            name           = "http"
          }

          # OIDC config via env (RUSTICAL_<SECTION>__<KEY>). Per upstream
          # docs, env vars are recommended over a config.toml because the
          # container ships only one binary.
          env {
            name  = "RUSTICAL_OIDC__NAME"
            value = "Zitadel"
          }
          env {
            name  = "RUSTICAL_OIDC__ISSUER"
            value = "https://${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"
          }
          env {
            name = "RUSTICAL_OIDC__CLIENT_ID"
            value_from {
              secret_key_ref {
                name = module.rustical_tls_vault.config_secret_name
                key  = "oidc_client_id"
              }
            }
          }
          env {
            name = "RUSTICAL_OIDC__CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = module.rustical_tls_vault.config_secret_name
                key  = "oidc_client_secret"
              }
            }
          }
          # `preferred_username` from Zitadel is the loginname
          #  That becomes the Rustical principal id. ICS URLs
          # will be /user@magic/<collection>/, ugly but stable. Future
          # tweak: project a custom claim that's just the local part.
          env {
            name  = "RUSTICAL_OIDC__CLAIM_USERID"
            value = "preferred_username"
          }
          env {
            name  = "RUSTICAL_OIDC__SCOPES"
            value = "[\"openid\", \"profile\", \"email\"]"
          }
          # Zitadel quirk: id_token aud always includes the project_id alongside
          # the client_id. The openidconnect-rs crate (used by rustical) rejects
          # any audience that isn't either the configured client_id or in
          # additional_audiences. Trust this service's own project_id.
          # (Upstream rustical PR #185 added this knob for exactly this scenario.)
          env {
            name  = "RUSTICAL_OIDC__ADDITIONAL_AUDIENCES"
            value = jsonencode([zitadel_project.rustical.id])
          }
          # JIT user provisioning: first OIDC login auto-creates a Rustical
          # principal. Fine for our single-user case; tighten later if more
          # users get added.
          env {
            name  = "RUSTICAL_OIDC__ALLOW_SIGN_UP"
            value = "true"
          }
          # Disable password login on the frontend. App tokens (per-DAV-client)
          # are still allowed for Thunderbird/iPhone — those are managed
          # via the frontend after OIDC sign-in.
          env {
            name  = "RUSTICAL_FRONTEND__ALLOW_PASSWORD_LOGIN"
            value = "false"
          }
          # Bind 0.0.0.0 so the in-pod nginx can reach it.
          env {
            name  = "RUSTICAL_HTTP__HOST"
            value = "0.0.0.0"
          }
          env {
            name  = "RUSTICAL_HTTP__PORT"
            value = "4000"
          }

          volume_mount {
            name       = "rustical-data"
            mount_path = "/var/lib/rustical"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }

          liveness_probe {
            tcp_socket { port = 4000 }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            tcp_socket { port = 4000 }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }

        # ─── Nginx (TLS termination + reverse proxy) ──────────────────────────
        container {
          name  = "rustical-nginx"
          image = var.image_nginx
          image_pull_policy = "Always"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "rustical-tls"
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

        # ─── Tailscale ────────────────────────────────────────────────────────
        container {
          name  = "rustical-tailscale"
          image = var.image_tailscale
          image_pull_policy = "Always"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.rustical_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.rustical_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.rustical_domain
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

        # ─── Volumes ──────────────────────────────────────────────────────────
        volume {
          name = "rustical-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.rustical_data.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.rustical_tls_vault.spc_name
            }
          }
        }
        volume {
          name = "rustical-tls"
          secret { secret_name = module.rustical_tls_vault.tls_secret_name }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.rustical_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "seed-script"
          config_map {
            name         = kubernetes_config_map.rustical_seed_script.metadata[0].name
            default_mode = "0755"
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
    module.rustical_tls_vault,
    module.rustical_netpol_baseline,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}
