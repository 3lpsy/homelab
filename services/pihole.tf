resource "kubernetes_namespace" "pihole" {
  metadata {
    name = "pihole"
  }
}

resource "kubernetes_service_account" "pihole" {
  metadata {
    name      = "pihole"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }
  automount_service_account_token = false
}

# Cookie key for the oauth2-proxy sidecar (32 alphanumeric bytes — satisfies
# oauth2-proxy's 32-byte requirement and dodges URL-encoding edge cases when
# exposed via the OAUTH2_PROXY_COOKIE_SECRET env var).
#
# Rotation forces every signed-in user to re-authenticate:
#   ./terraform.sh services apply -replace=random_password.pihole_oauth2_cookie
resource "random_password" "pihole_oauth2_cookie" {
  length  = 32
  special = false
}

# ─── Zitadel project + role + OIDC application + per-user grant ──────────────
#
# Per memory `feedback_zitadel_one_project_per_service`, each onboarded service
# declares its own project. project_role_check=true so Zitadel itself rejects
# token issuance for users without a grant — only the personal user can ever
# get past oauth2-proxy.
#
# Single role (`admin`) — pihole has no concept of viewer-vs-admin at the
# OIDC layer and oauth2-proxy doesn't need to inspect groups. Pihole's own
# webpassword is disabled (FTLCONF_webserver_api_password=""); FTL binds to
# 127.0.0.1, so oauth2-proxy is the sole auth gate.
resource "zitadel_project" "pihole" {
  name   = "pihole"
  org_id = data.zitadel_organizations.homelab.ids[0]

  project_role_assertion   = true
  project_role_check       = true
  has_project_check        = true
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"
}

resource "zitadel_project_role" "pihole_admin" {
  org_id       = data.zitadel_organizations.homelab.ids[0]
  project_id   = zitadel_project.pihole.id
  role_key     = "admin"
  display_name = "Pi-hole admin"
}

resource "zitadel_application_oidc" "pihole" {
  name       = "Pi-hole"
  org_id     = data.zitadel_organizations.homelab.ids[0]
  project_id = zitadel_project.pihole.id

  redirect_uris             = ["https://${var.pihole_domain}.${local.magic_fqdn_suffix}/oauth2/callback"]
  post_logout_redirect_uris = ["https://${var.pihole_domain}.${local.magic_fqdn_suffix}/"]

  response_types   = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types      = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"]
  app_type         = "OIDC_APP_TYPE_WEB"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_BASIC"
  dev_mode         = false
}

resource "zitadel_user_grant" "pihole_personal_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.personal.id
  project_id = zitadel_project.pihole.id
  role_keys  = [zitadel_project_role.pihole_admin.role_key]
}

module "pihole_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "pihole"
  namespace            = kubernetes_namespace.pihole.metadata[0].name
  service_account_name = kubernetes_service_account.pihole.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.pihole_server_user
}

module "pihole_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "pihole"
  namespace            = kubernetes_namespace.pihole.metadata[0].name
  service_account_name = kubernetes_service_account.pihole.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = "${var.pihole_domain}.${local.magic_fqdn_suffix}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  config_secrets = {
    # No pihole webpassword — pihole-FTL binds to 127.0.0.1 (see
    # FTLCONF_webserver_interface_address on the pihole container) so the
    # admin UI is unreachable except via nginx-on-localhost, which is
    # gated by oauth2-proxy. OIDC is the single source of admin auth.
    oidc_client_id       = zitadel_application_oidc.pihole.client_id
    oidc_client_secret   = zitadel_application_oidc.pihole.client_secret
    oauth2_cookie_secret = random_password.pihole_oauth2_cookie.result
  }

  providers = { acme = acme }
}

resource "kubernetes_persistent_volume_claim" "pihole_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "pihole-data"
    namespace = kubernetes_namespace.pihole.metadata[0].name
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

resource "kubernetes_config_map" "pihole_nginx_config" {
  metadata {
    name      = "pihole-nginx-config"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/pihole.nginx.conf.tpl", {
      server_domain       = "${var.pihole_domain}.${local.magic_fqdn_suffix}"
      nginx_logging_block = local.nginx_logging_blocks["pihole"]
    })
  }
}

# Single-pod namespace. Pihole serves DNS to tailnet devices via its
# Tailscale sidecar (NetPol-invisible). Internet egress (covered by
# baseline) is required for Pihole's upstream DNS resolvers.
module "pihole_netpol_baseline" {
  source = "../templates/netpol-baseline"

  namespace    = kubernetes_namespace.pihole.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

resource "kubernetes_deployment" "pihole" {
  metadata {
    name      = "pihole"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "pihole" }
    }

    template {
      metadata {
        labels = { app = "pihole" }
        annotations = {
          "nginx-config-hash"                   = sha1(kubernetes_config_map.pihole_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "${module.pihole_tls_vault.config_secret_name},${module.pihole_tls_vault.tls_secret_name}"
          # Upstream DNS settings come from FTLCONF env vars. Query log +
          # gravity blocklist DB rebuild on first start. Nothing in this
          # PVC is irreplaceable.
          "backup.velero.io/backup-volumes-excludes" = "pihole-data"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.pihole.metadata[0].name

        # Pin oidc.<tailnet> to the Zitadel ClusterIP for SNI/cert validation
        # without a Tailscale egress sidecar (memory: feedback_no_egress_only_ts_sidecars).
        # oauth2-proxy speaks to Zitadel via this alias for discovery, JWKS,
        # token exchange, and userinfo.
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
              # Gate on the OIDC client_id — only config_secret the pod
              # actually depends on (oauth2-proxy reads it via env). The
              # other two oauth2 keys are written in the same Vault round-
              # trip, so a present client_id implies they're present too.
              secret_file = "oidc_client_id"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # PiHole
        container {
          name  = "pihole"
          image = var.image_pihole
          image_pull_policy = "Always"

          # Empty-string disables pihole's own login. Combined with the
          # localhost-only bind below this means the UI has exactly one auth
          # gate: oauth2-proxy in front of nginx. Removing the password env
          # entirely would leave FTL with no value and trigger its random-
          # password fallback (which is then printed to stdout) — not what
          # we want, so set it explicitly to "".
          env {
            name  = "FTLCONF_webserver_api_password"
            value = ""
          }
          # Bind pihole-FTL's HTTP admin to localhost only. nginx (same pod
          # netns) still reaches it via 127.0.0.1:80; the tailscale sidecar
          # exposes the netns to the tailnet, so leaving FTL on 0.0.0.0
          # would mean any tailnet device could `curl http://pihole.<magic>/`
          # and bypass nginx + oauth2-proxy entirely.
          env {
            name  = "FTLCONF_webserver_interface_address"
            value = "127.0.0.1"
          }
          # Drop FTL's built-in TLS listener on :443. nginx sidecar owns
          # 443 in this pod (pod netns is shared); FTL v6's default
          # `80o,443os,[::]:80o,[::]:443os` races nginx on :443 at pod
          # startup. Restrict FTL to :80 only so nginx wins deterministically.
          env {
            name  = "FTLCONF_webserver_port"
            value = "80o,[::]:80o"
          }
          env {
            name  = "FTLCONF_dns_upstreams"
            value = "9.9.9.9;149.112.112.112"
          }
          env {
            name  = "FTLCONF_dns_listeningMode"
            value = "all"
          }
          env {
            name  = "TZ"
            value = "America/Chicago"
          }

          # No `port { container_port = 80 }` declared — pihole-FTL is bound
          # to 127.0.0.1:80 (FTLCONF_webserver_interface_address above) and
          # only the same-pod nginx talks to it. The DNS ports below are
          # declared because the tailscale sidecar deliberately exposes
          # them on the tailnet for client lookups.
          port {
            container_port = 53
            protocol       = "UDP"
            name           = "dns-udp"
          }
          port {
            container_port = 53
            protocol       = "TCP"
            name           = "dns-tcp"
          }

          volume_mount {
            name       = "pihole-data"
            mount_path = "/etc/pihole"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }

          # TCP probe on the DNS port. pihole-FTL keeps :53 bound to 0.0.0.0
          # (DNS to tailnet clients is the whole reason this pod exists), so
          # a successful TCP connect confirms FTL is up. Avoids probing
          # :80 (now localhost-only, kubelet can't reach it) and avoids
          # carving an unauth /healthz hole in nginx that would re-expose
          # the now-passwordless admin UI to any tailnet device.
          liveness_probe {
            tcp_socket {
              port = 53
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            tcp_socket {
              port = 53
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        # PiHole Volumes
        volume {
          name = "pihole-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.pihole_data.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.pihole_tls_vault.spc_name
            }
          }
        }

        # Nginx
        container {
          name  = "pihole-nginx"
          image = var.image_nginx
          image_pull_policy = "Always"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "pihole-tls"
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
          name = "pihole-tls"
          secret { secret_name = module.pihole_tls_vault.tls_secret_name }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.pihole_nginx_config.metadata[0].name
          }
        }

        # oauth2-proxy: handles the OIDC code+PKCE flow against Zitadel and
        # answers the /oauth2/auth subrequest from nginx. Auth-only mode —
        # nginx talks to pihole's port 80 directly; oauth2-proxy never sees
        # body traffic. Listens on 127.0.0.1:4180 (pod-local; no Service).
        #
        # No groups claim or scope mapping: pihole has a single role, and
        # access is enforced upstream by Zitadel's project_role_check (only
        # the personal user is granted on this project).
        container {
          name  = "pihole-oauth2-proxy"
          image = var.image_oauth2_proxy
          image_pull_policy = "Always"

          env {
            name  = "OAUTH2_PROXY_PROVIDER"
            value = "oidc"
          }
          env {
            name  = "OAUTH2_PROXY_OIDC_ISSUER_URL"
            value = "https://${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"
          }
          env {
            name  = "OAUTH2_PROXY_REDIRECT_URL"
            value = "https://${var.pihole_domain}.${local.magic_fqdn_suffix}/oauth2/callback"
          }
          env {
            name  = "OAUTH2_PROXY_HTTP_ADDRESS"
            value = "127.0.0.1:4180"
          }
          env {
            name  = "OAUTH2_PROXY_REVERSE_PROXY"
            value = "true"
          }
          # Auth-only mode: respond 202 to /oauth2/auth subrequests, never
          # proxy real traffic upstream.
          env {
            name  = "OAUTH2_PROXY_UPSTREAMS"
            value = "static://202"
          }
          # Project access enforced by Zitadel's project_role_check; no
          # email-domain restriction layered on here.
          env {
            name  = "OAUTH2_PROXY_EMAIL_DOMAINS"
            value = "*"
          }
          env {
            name  = "OAUTH2_PROXY_SET_XAUTHREQUEST"
            value = "true"
          }
          env {
            name  = "OAUTH2_PROXY_PASS_USER_HEADERS"
            value = "true"
          }
          # Single-IdP setup; skip the provider-picker page that
          # oauth2-proxy otherwise shows before redirecting to Zitadel.
          env {
            name  = "OAUTH2_PROXY_SKIP_PROVIDER_BUTTON"
            value = "true"
          }
          env {
            name  = "OAUTH2_PROXY_COOKIE_SECURE"
            value = "true"
          }
          env {
            name  = "OAUTH2_PROXY_COOKIE_DOMAINS"
            value = "${var.pihole_domain}.${local.magic_fqdn_suffix}"
          }
          # Whitelist both pihole.<magic> and oidc.<magic>: oauth2-proxy
          # validates `?rd=` redirects and any RP-initiated logout chain
          # against this list.
          env {
            name  = "OAUTH2_PROXY_WHITELIST_DOMAINS"
            value = "${var.pihole_domain}.${local.magic_fqdn_suffix},${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"
          }

          env {
            name = "OAUTH2_PROXY_CLIENT_ID"
            value_from {
              secret_key_ref {
                name = module.pihole_tls_vault.config_secret_name
                key  = "oidc_client_id"
              }
            }
          }
          env {
            name = "OAUTH2_PROXY_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = module.pihole_tls_vault.config_secret_name
                key  = "oidc_client_secret"
              }
            }
          }
          env {
            name = "OAUTH2_PROXY_COOKIE_SECRET"
            value_from {
              secret_key_ref {
                name = module.pihole_tls_vault.config_secret_name
                key  = "oauth2_cookie_secret"
              }
            }
          }

          resources {
            requests = { cpu = "20m", memory = "32Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        # Tailscale
        container {
          name  = "pihole-tailscale"
          image = var.image_tailscale
          image_pull_policy = "Always"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.pihole_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.pihole_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.pihole_domain
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
              add = ["NET_ADMIN", "NET_BIND_SERVICE", "NET_RAW", "SYS_NICE", "CHOWN"]
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
    module.pihole_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}
