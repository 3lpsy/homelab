resource "kubernetes_namespace" "pdf" {
  metadata {
    name = "pdf"
  }
}

resource "kubernetes_service_account" "pdf" {
  metadata {
    name      = "pdf"
    namespace = kubernetes_namespace.pdf.metadata[0].name
  }
  automount_service_account_token = false
}

locals {
  pdf_fqdn = "${var.pdf_domain}.${local.magic_fqdn_suffix}"
}

# Cookie key for the oauth2-proxy sidecar (32 alphanumeric bytes — satisfies
# oauth2-proxy's 32-byte requirement and dodges URL-encoding edge cases when
# exposed via the OAUTH2_PROXY_COOKIE_SECRET env var).
resource "random_password" "pdf_oauth2_cookie" {
  length  = 32
  special = false
}

# ─── Zitadel project + role + OIDC application + per-user grants ─────────
#
# Stirling-PDF v2.1+ gates its built-in OAuth2/OIDC behind a paid Server
# license (`errorOAuth=oAuth2RequiresLicense`; logs show
# `License check result: type=NORMAL, requiresPaid=true, hasPaid=false`).
# Auto-Login is Enterprise-tier, SAML is Enterprise. We don't have a paid
# license, so the app runs with DOCKER_ENABLE_SECURITY=false and an
# oauth2-proxy sidecar (pattern mirror of services/pihole.tf) enforces
# the OIDC code+PKCE flow against Zitadel before any request reaches
# Stirling-PDF's port.
#
# project_role_check=true so Zitadel itself rejects token issuance for
# users without a grant — only personal + partner can sign in.
resource "zitadel_project" "pdf" {
  name   = "stirling-pdf"
  org_id = data.zitadel_organizations.homelab.ids[0]

  project_role_assertion   = true
  project_role_check       = true
  has_project_check        = true
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"
}

resource "zitadel_project_role" "pdf_user" {
  org_id       = data.zitadel_organizations.homelab.ids[0]
  project_id   = zitadel_project.pdf.id
  role_key     = "user"
  display_name = "Stirling-PDF user"
}

# Callback URL is the oauth2-proxy default `/oauth2/callback`, NOT
# Stirling-PDF's own Spring Security endpoint (which is paywalled).
resource "zitadel_application_oidc" "pdf" {
  name       = "Stirling-PDF"
  org_id     = data.zitadel_organizations.homelab.ids[0]
  project_id = zitadel_project.pdf.id

  redirect_uris             = ["https://${local.pdf_fqdn}/oauth2/callback"]
  post_logout_redirect_uris = ["https://${local.pdf_fqdn}/"]

  response_types   = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types      = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"]
  app_type         = "OIDC_APP_TYPE_WEB"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_BASIC"
  dev_mode         = false
}

resource "zitadel_user_grant" "pdf_personal_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.personal.id
  project_id = zitadel_project.pdf.id
  role_keys  = [zitadel_project_role.pdf_user.role_key]
}

resource "zitadel_user_grant" "pdf_partner_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.partner.id
  project_id = zitadel_project.pdf.id
  role_keys  = [zitadel_project_role.pdf_user.role_key]
}

module "pdf_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "pdf"
  namespace            = kubernetes_namespace.pdf.metadata[0].name
  service_account_name = kubernetes_service_account.pdf.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.pdf_server_user
}

module "pdf_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "pdf"
  namespace            = kubernetes_namespace.pdf.metadata[0].name
  service_account_name = kubernetes_service_account.pdf.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = local.pdf_fqdn
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  config_secrets = {
    oidc_client_id       = zitadel_application_oidc.pdf.client_id
    oidc_client_secret   = zitadel_application_oidc.pdf.client_secret
    oauth2_cookie_secret = random_password.pdf_oauth2_cookie.result
  }

  providers = { acme = acme }
}

resource "kubernetes_persistent_volume_claim" "pdf_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "pdf-data"
    namespace = kubernetes_namespace.pdf.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.pdf_storage_size
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_config_map" "pdf_nginx_config" {
  metadata {
    name      = "pdf-nginx-config"
    namespace = kubernetes_namespace.pdf.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/pdf.nginx.conf.tpl", {
      server_domain       = local.pdf_fqdn
      nginx_logging_block = local.nginx_logging_blocks["pdf"]
    })
  }
}

module "pdf_netpol_baseline" {
  source = "../templates/netpol-baseline"

  namespace    = kubernetes_namespace.pdf.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
  # Tailscale sidecar reaches Headscale + DERP; OIDC token exchange
  # against Zitadel goes via host_aliases (cross-ns, allowed below).
  allow_internet_egress = true
  # Tailscale sidecar uses TS_KUBE_SECRET to persist state to a k8s Secret.
  allow_kube_api_egress = true
}

# Cross-ns egress: pdf → oidc:443 for the OIDC sign-in flow against
# Zitadel. Mirror ingress lives in services/zitadel-network.tf as
# oidc-from-pdf.
resource "kubernetes_network_policy" "pdf_to_oidc" {
  metadata {
    name      = "pdf-to-oidc"
    namespace = kubernetes_namespace.pdf.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { app = "pdf" }
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

resource "kubernetes_deployment" "pdf" {
  metadata {
    name      = "pdf"
    namespace = kubernetes_namespace.pdf.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "pdf" }
    }

    template {
      metadata {
        labels = { app = "pdf" }
        annotations = {
          "nginx-config-hash"                   = sha1(kubernetes_config_map.pdf_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "${module.pdf_tls_vault.config_secret_name},${module.pdf_tls_vault.tls_secret_name}"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.pdf.metadata[0].name

        # In-cluster reach to Zitadel for OIDC discovery + token exchange.
        # Pin oidc.<tailnet> to the Zitadel Service ClusterIP so SNI + LE
        # cert validate without going through a tailscale egress sidecar.
        host_aliases {
          ip        = data.terraform_remote_state.vault_conf.outputs.zitadel_cluster_ip
          hostnames = ["${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"]
        }

        # Wait for Vault CSI secrets
        init_container {
          name              = "wait-for-secrets"
          image             = var.image_busybox
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

        # Stirling-PDF image runs as uid 1000.
        init_container {
          name              = "fix-permissions"
          image             = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            "mkdir -p /pvc/configs /pvc/customFiles && chown -R 1000:1000 /pvc"
          ]
          volume_mount {
            name       = "pdf-data"
            mount_path = "/pvc"
          }
        }

        # Stirling-PDF
        container {
          name              = "pdf"
          image             = var.image_stirling_pdf
          image_pull_policy = "Always"

          port {
            container_port = 8080
            name           = "http"
          }

          env {
            name  = "SERVER_PORT"
            value = "8080"
          }
          # Spring binds 0.0.0.0:8080 inside the pod netns. Direct tailnet
          # access to :8080 is blocked by the headscale ACL (acls_pdf
          # only opens group:pdf-server:443), so the oauth2-proxy + nginx
          # path on :443 is the sole reachable surface. Pinning to
          # 127.0.0.1 breaks the kubelet readiness probe (probe runs from
          # host netns, hits podIP:8080).
          # Built-in auth disabled — Stirling-PDF v2.1+ paywalls all
          # OAuth2/OIDC ("oAuth2RequiresLicense"). Auth gate is oauth2-proxy
          # in front of nginx (same pod). DOCKER_ENABLE_SECURITY is a
          # build-time hint the prebuilt image ignores; the runtime
          # kill-switch is SECURITY_ENABLELOGIN (Spring property
          # `security.enableLogin`). Both set for belt-and-suspenders.
          env {
            name  = "DOCKER_ENABLE_SECURITY"
            value = "false"
          }
          env {
            name  = "SECURITY_ENABLELOGIN"
            value = "false"
          }
          # Skip optional heavy deps (Calibre / advanced HTML ops) and
          # extra OCR languages to keep the image lean.
          env {
            name  = "INSTALL_BOOK_AND_ADVANCED_HTML_OPS"
            value = "false"
          }
          env {
            name  = "LANGS"
            value = "en_US"
          }

          volume_mount {
            name       = "pdf-data"
            mount_path = "/configs"
            sub_path   = "configs"
          }
          volume_mount {
            name       = "pdf-data"
            mount_path = "/customFiles"
            sub_path   = "customFiles"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          # Java + LibreOffice + OCR are spiky.
          resources {
            requests = { cpu = "300m", memory = "512Mi" }
            limits   = { cpu = "1500m", memory = "2Gi" }
          }

          # Stirling-PDF's `/` is gated by Spring Security (returns 401
          # even with SECURITY_ENABLELOGIN=false). `/api/v1/info/status`
          # is intentionally unauthenticated — used for liveness checks.
          liveness_probe {
            http_get {
              path = "/api/v1/info/status"
              port = 8080
            }
            initial_delay_seconds = 90
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/api/v1/info/status"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        # Stirling-PDF Volumes
        volume {
          name = "pdf-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.pdf_data.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.pdf_tls_vault.spc_name
            }
          }
        }

        # Nginx
        container {
          name              = "nginx"
          image             = var.image_nginx
          image_pull_policy = "Always"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "pdf-tls"
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
          name = "pdf-tls"
          secret { secret_name = module.pdf_tls_vault.tls_secret_name }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.pdf_nginx_config.metadata[0].name
          }
        }

        # oauth2-proxy: handles the OIDC code+PKCE flow against Zitadel and
        # answers the /oauth2/auth subrequest from nginx. Auth-only mode —
        # nginx talks to Stirling-PDF on localhost:8080 directly;
        # oauth2-proxy never sees the body. Listens on 127.0.0.1:4180.
        container {
          name              = "pdf-oauth2-proxy"
          image             = var.image_oauth2_proxy
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
            value = "https://${local.pdf_fqdn}/oauth2/callback"
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
          # Single-IdP setup; skip the provider-picker page.
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
            value = local.pdf_fqdn
          }
          # oauth2-proxy validates `?rd=` redirects + RP-initiated logout
          # chain against this whitelist.
          env {
            name  = "OAUTH2_PROXY_WHITELIST_DOMAINS"
            value = "${local.pdf_fqdn},${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"
          }

          env {
            name = "OAUTH2_PROXY_CLIENT_ID"
            value_from {
              secret_key_ref {
                name = module.pdf_tls_vault.config_secret_name
                key  = "oidc_client_id"
              }
            }
          }
          env {
            name = "OAUTH2_PROXY_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = module.pdf_tls_vault.config_secret_name
                key  = "oidc_client_secret"
              }
            }
          }
          env {
            name = "OAUTH2_PROXY_COOKIE_SECRET"
            value_from {
              secret_key_ref {
                name = module.pdf_tls_vault.config_secret_name
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
          name              = "tailscale"
          image             = var.image_tailscale
          image_pull_policy = "Always"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.pdf_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.pdf_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.pdf_domain
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

          volume_mount {
            name       = "dev-net-tun"
            mount_path = "/dev/net/tun"
          }
          volume_mount {
            name       = "tailscale-state"
            mount_path = "/var/lib/tailscale"
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "192Mi" }
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
    module.pdf_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}
