resource "kubernetes_namespace" "headlamp" {
  metadata {
    name = "headlamp"
  }
}

resource "kubernetes_service_account" "headlamp" {
  metadata {
    name      = "headlamp"
    namespace = kubernetes_namespace.headlamp.metadata[0].name
  }
}

# Long-lived SA token. Headlamp's proxy at /clusters/<name>/* reads the
# Bearer it forwards to apiserver from a cookie named
# `headlamp-auth-<cluster>.0` — there is NO fallback to the projected
# /var/run/secrets SA token (per backend/pkg/auth/cookies.go). nginx
# injects this cookie on every gated request so the browser session is
# transparent: oauth2-proxy gates the user, nginx attaches the SA's
# token, Headlamp uses it. legacy service-account-token Secrets are
# non-rotating, so the rendered nginx.conf doesn't need refresh.
resource "kubernetes_secret" "headlamp_sa_token" {
  metadata {
    name      = "headlamp-sa-token"
    namespace = kubernetes_namespace.headlamp.metadata[0].name
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.headlamp.metadata[0].name
    }
  }
  type = "kubernetes.io/service-account-token"

  # `data.token`, `data.ca.crt`, `data.namespace` populated by the k8s
  # TokenController after this resource is created.
  lifecycle {
    ignore_changes = [data]
  }
}

# Read-only cluster access. Mirrors the upstream Headlamp Helm chart's
# default ClusterRole (charts/headlamp/templates/clusterrole.yaml) — the
# built-in `view` role omits nodes, PVs, storageclasses, CRDs, and
# metrics.k8s.io, so the UI's home page (CPU/memory/node count) and any
# CRD-aware view 401s without these. Verbs are get/list/watch only — no
# create/update/delete/patch — so the worst a compromised session can
# do is read state. Single-admin homelab: secrets visibility is OK.
resource "kubernetes_cluster_role" "headlamp_reader" {
  metadata {
    name = "headlamp-reader"
  }

  rule {
    api_groups = [""]
    resources  = ["*"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["apps", "batch", "networking.k8s.io", "policy", "rbac.authorization.k8s.io", "storage.k8s.io", "discovery.k8s.io"]
    resources  = ["*"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["metrics.k8s.io"]
    resources  = ["nodes", "pods"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["apiextensions.k8s.io"]
    resources  = ["customresourcedefinitions"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "headlamp_reader" {
  metadata {
    name = "headlamp-reader"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.headlamp_reader.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.headlamp.metadata[0].name
    namespace = kubernetes_namespace.headlamp.metadata[0].name
  }
}

locals {
  headlamp_fqdn = "${var.headlamp_domain}.${local.magic_fqdn_suffix}"
}

# Cookie key for the oauth2-proxy sidecar (32 alphanumeric bytes — satisfies
# oauth2-proxy's 32-byte requirement and dodges URL-encoding edge cases).
# Rotate to invalidate every session:
#   ./terraform.sh services apply -replace=random_password.headlamp_oauth2_cookie
resource "random_password" "headlamp_oauth2_cookie" {
  length  = 32
  special = false
}

# Zitadel project + role + OIDC client. project_role_check=true so Zitadel
# rejects token issuance for users without a grant — only the personal user
# can ever pass oauth2-proxy. Per memory feedback_zitadel_one_project_per_service.
resource "zitadel_project" "headlamp" {
  name   = "headlamp"
  org_id = data.zitadel_organizations.homelab.ids[0]

  project_role_assertion   = true
  project_role_check       = true
  has_project_check        = true
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"
}

resource "zitadel_project_role" "headlamp_admin" {
  org_id       = data.zitadel_organizations.homelab.ids[0]
  project_id   = zitadel_project.headlamp.id
  role_key     = "admin"
  display_name = "Headlamp admin"
}

resource "zitadel_application_oidc" "headlamp" {
  name       = "Headlamp"
  org_id     = data.zitadel_organizations.homelab.ids[0]
  project_id = zitadel_project.headlamp.id

  redirect_uris             = ["https://${local.headlamp_fqdn}/oauth2/callback"]
  post_logout_redirect_uris = ["https://${local.headlamp_fqdn}/"]

  response_types   = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types      = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"]
  app_type         = "OIDC_APP_TYPE_WEB"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_BASIC"
  dev_mode         = false
}

resource "zitadel_user_grant" "headlamp_personal_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.personal.id
  project_id = zitadel_project.headlamp.id
  role_keys  = [zitadel_project_role.headlamp_admin.role_key]
}

module "headlamp_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "headlamp"
  namespace            = kubernetes_namespace.headlamp.metadata[0].name
  service_account_name = kubernetes_service_account.headlamp.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.headlamp_server_user
}

module "headlamp_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "headlamp"
  namespace            = kubernetes_namespace.headlamp.metadata[0].name
  service_account_name = kubernetes_service_account.headlamp.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = local.headlamp_fqdn
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  config_secrets = {
    oidc_client_id       = zitadel_application_oidc.headlamp.client_id
    oidc_client_secret   = zitadel_application_oidc.headlamp.client_secret
    oauth2_cookie_secret = random_password.headlamp_oauth2_cookie.result
  }

  providers = { acme = acme }
}

resource "kubernetes_config_map" "headlamp_nginx_config" {
  metadata {
    name      = "headlamp-nginx-config"
    namespace = kubernetes_namespace.headlamp.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/headlamp.nginx.conf.tpl", {
      server_domain       = local.headlamp_fqdn
      nginx_logging_block = local.nginx_logging_blocks["headlamp"]
    })
  }
}

resource "kubernetes_deployment" "headlamp" {
  metadata {
    name      = "headlamp"
    namespace = kubernetes_namespace.headlamp.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "headlamp" }
    }

    template {
      metadata {
        labels = { app = "headlamp" }
        annotations = {
          "nginx-config-hash"                   = sha1(kubernetes_config_map.headlamp_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "${module.headlamp_tls_vault.config_secret_name},${module.headlamp_tls_vault.tls_secret_name},${kubernetes_secret.headlamp_sa_token.metadata[0].name}"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.headlamp.metadata[0].name

        # Pin oidc.<tailnet> to the Zitadel Service ClusterIP so OIDC
        # discovery + token exchange validates LE certs in-cluster
        # without an egress tailscale sidecar (feedback_no_egress_only_ts_sidecars).
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

        # Render nginx.conf, substituting the SA's long-lived token into
        # the headlamp-auth cookie placeholder. Output goes to a shared
        # emptyDir that the nginx container mounts at /etc/nginx/nginx.conf.
        # Uses sed with `|` delimiter — JWT tokens contain only
        # base64url-safe chars (alphanumerics, `-`, `_`, `.`) so no escape
        # collisions with the delimiter.
        init_container {
          name              = "inject-sa-token"
          image             = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            <<-EOT
              set -eu
              ATTEMPT=0
              while [ $ATTEMPT -lt 60 ]; do
                [ -s /etc/sa-token/token ] && break
                echo "Waiting for SA token to be populated by k8s TokenController..."
                sleep 1
                ATTEMPT=$((ATTEMPT + 1))
              done
              [ -s /etc/sa-token/token ] || { echo "SA token not populated after 60s"; exit 1; }
              TOKEN=$(cat /etc/sa-token/token)
              sed "s|__HEADLAMP_SA_TOKEN__|$TOKEN|" /etc/nginx-template/nginx.conf > /etc/nginx-rendered/nginx.conf
            EOT
          ]
          volume_mount {
            name       = "sa-token"
            mount_path = "/etc/sa-token"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-template"
            mount_path = "/etc/nginx-template"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-rendered"
            mount_path = "/etc/nginx-rendered"
          }
        }

        # Headlamp
        container {
          name              = "headlamp"
          image             = var.image_headlamp
          image_pull_policy = "Always"

          # `-in-cluster` makes headlamp use the pod SA token to talk to
          # kube-apiserver. No -oidc-* flags: OIDC is enforced by the
          # oauth2-proxy sidecar in front of nginx. Headlamp itself
          # serves cluster ops with the SA token, which the
          # `headlamp-view` ClusterRoleBinding maps to `view`.
          args = [
            "-in-cluster",
            "-port", "4466",
            "-html-static-dir", "/headlamp/frontend",
          ]

          port {
            container_port = 4466
            name           = "http"
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "300m", memory = "256Mi" }
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 4466
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 4466
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }

        # Nginx — TLS termination + reverse proxy to localhost:4466
        container {
          name              = "nginx"
          image             = var.image_nginx
          image_pull_policy = "Always"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "headlamp-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }
          # Rendered config (token substituted) from the inject-sa-token
          # init container, not the raw ConfigMap.
          volume_mount {
            name       = "nginx-rendered"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
            read_only  = true
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        # oauth2-proxy: handles the OIDC code+PKCE flow against Zitadel and
        # answers nginx's /oauth2/auth subrequest. Auth-only mode — body
        # traffic flows nginx -> headlamp directly. Listens on 127.0.0.1:4180.
        # Per-user enforcement is at Zitadel (project_role_check=true + the
        # personal user is the only granted user); no email-domain layer here.
        container {
          name              = "oauth2-proxy"
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
            value = "https://${local.headlamp_fqdn}/oauth2/callback"
          }
          env {
            name  = "OAUTH2_PROXY_HTTP_ADDRESS"
            value = "127.0.0.1:4180"
          }
          env {
            name  = "OAUTH2_PROXY_REVERSE_PROXY"
            value = "true"
          }
          # Auth-only mode: 202 on success, oauth2-proxy never proxies
          # body traffic.
          env {
            name  = "OAUTH2_PROXY_UPSTREAMS"
            value = "static://202"
          }
          # Single-user gate is enforced upstream by Zitadel's
          # project_role_check (only the personal user has a grant).
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
            value = local.headlamp_fqdn
          }
          env {
            name  = "OAUTH2_PROXY_WHITELIST_DOMAINS"
            value = "${local.headlamp_fqdn},${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"
          }

          env {
            name = "OAUTH2_PROXY_CLIENT_ID"
            value_from {
              secret_key_ref {
                name = module.headlamp_tls_vault.config_secret_name
                key  = "oidc_client_id"
              }
            }
          }
          env {
            name = "OAUTH2_PROXY_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = module.headlamp_tls_vault.config_secret_name
                key  = "oidc_client_secret"
              }
            }
          }
          env {
            name = "OAUTH2_PROXY_COOKIE_SECRET"
            value_from {
              secret_key_ref {
                name = module.headlamp_tls_vault.config_secret_name
                key  = "oauth2_cookie_secret"
              }
            }
          }

          resources {
            requests = { cpu = "20m", memory = "32Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        # Tailscale ingress sidecar
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
            value = module.headlamp_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.headlamp_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.headlamp_domain
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

        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.headlamp_tls_vault.spc_name
            }
          }
        }
        volume {
          name = "headlamp-tls"
          secret { secret_name = module.headlamp_tls_vault.tls_secret_name }
        }
        volume {
          name = "nginx-template"
          config_map {
            name = kubernetes_config_map.headlamp_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "nginx-rendered"
          empty_dir {}
        }
        volume {
          name = "sa-token"
          secret {
            secret_name = kubernetes_secret.headlamp_sa_token.metadata[0].name
            items {
              key  = "token"
              path = "token"
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
    module.headlamp_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

# =============================================================================
# NetworkPolicies for the `headlamp` namespace.
#
# Single-pod namespace (headlamp + nginx + tailscale sidecars). Cross-ns
# flows this file owns:
#   - egress  headlamp → oidc:443 (OIDC sign-in)
#   - egress  headlamp → kube-apiserver:6443 (covered by netpol-baseline
#             allow_kube_api_egress; Headlamp uses its SA token to talk
#             to kubernetes.default.svc which kube-proxy DNATs to host:6443)
# =============================================================================

module "headlamp_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.headlamp.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
  # Tailscale sidecar reaches Headscale + DERP; oauth2 token exchange
  # against Zitadel goes via host_aliases (cross-ns, allowed below).
  allow_internet_egress = true
  # Headlamp talks to kube-apiserver on every page load; tailscale
  # sidecar also persists state to a k8s Secret via TS_KUBE_SECRET.
  allow_kube_api_egress = true
}

# Cross-ns egress: headlamp → oidc:443 for the OIDC sign-in flow against
# Zitadel. Mirror ingress lives in services/zitadel-network.tf as
# oidc-from-headlamp.
resource "kubernetes_network_policy" "headlamp_to_oidc" {
  metadata {
    name      = "headlamp-to-oidc"
    namespace = kubernetes_namespace.headlamp.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { app = "headlamp" }
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

