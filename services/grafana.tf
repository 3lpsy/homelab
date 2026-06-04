resource "kubernetes_namespace" "grafana" {
  metadata {
    name = "grafana"
  }
}

resource "kubernetes_service_account" "grafana" {
  metadata {
    name      = "grafana"
    namespace = kubernetes_namespace.grafana.metadata[0].name
  }
  automount_service_account_token = false
}

resource "random_password" "grafana_admin" {
  length  = 32
  special = false
}

# Zitadel OIDC client for Grafana. client_id + client_secret flow through
# module.grafana_tls_vault config_secrets → Vault → CSI → k8s Secret →
# GF_AUTH_GENERIC_OAUTH_* envs. Local admin login (random_password.grafana_admin)
# stays as escape hatch.
locals {
  grafana_fqdn        = "${var.grafana_domain}.${local.magic_fqdn_suffix}"
  zitadel_issuer_url  = "https://${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"
}

resource "zitadel_project" "grafana" {
  name   = "grafana"
  org_id = data.zitadel_organizations.homelab.ids[0]

  # Loose authz today: any Zitadel user with org membership can sign in
  # to Grafana (project_grafana_oidc_authz_pending.md). Flip the *_check
  # fields to true + enforce role_keys on the user_grant once Grafana is
  # ready to be locked down.
  project_role_assertion   = false
  project_role_check       = false
  has_project_check        = false
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"
}

resource "zitadel_application_oidc" "grafana" {
  name       = "Grafana"
  org_id     = data.zitadel_organizations.homelab.ids[0]
  project_id = zitadel_project.grafana.id

  redirect_uris             = ["https://${local.grafana_fqdn}/login/generic_oauth"]
  post_logout_redirect_uris = ["https://${local.grafana_fqdn}/logout"]

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

# Per-user grant for `jim`. No-op for authorization enforcement today
# (project_role_check=false above) but pre-positioned for when authz is
# actually flipped on (project_grafana_oidc_authz_pending.md).
resource "zitadel_user_grant" "grafana_personal_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.personal.id
  project_id = zitadel_project.grafana.id
  role_keys  = []
}

module "grafana_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "grafana"
  namespace            = kubernetes_namespace.grafana.metadata[0].name
  service_account_name = kubernetes_service_account.grafana.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.grafana_server_user
}

module "grafana_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "grafana"
  namespace            = kubernetes_namespace.grafana.metadata[0].name
  service_account_name = kubernetes_service_account.grafana.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = "${var.grafana_domain}.${local.magic_fqdn_suffix}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  config_secrets = {
    admin_password     = random_password.grafana_admin.result
    oidc_client_id     = zitadel_application_oidc.grafana.client_id
    oidc_client_secret = zitadel_application_oidc.grafana.client_secret
  }

  providers = { acme = acme }
}

resource "kubernetes_persistent_volume_claim" "grafana_data" {
  # No prevent_destroy: dashboards + datasources are provisioned from
  # Terraform (services-conf/dashboards.tf via the Grafana provider; the
  # datasources ConfigMap above), so the SQLite at /var/lib/grafana/grafana.db
  # only holds: user accounts, alert state, hand-edited dashboards. Losing
  # this PVC means re-creating any UI-only edits — provisioned content
  # is restored automatically on first start.
  metadata {
    name      = "grafana-data"
    namespace = kubernetes_namespace.grafana.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.grafana_storage_size
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_config_map" "grafana_datasources" {
  metadata {
    name      = "grafana-datasources"
    namespace = kubernetes_namespace.grafana.metadata[0].name
  }
  data = {
    "datasources.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name      = "Prometheus"
        type      = "prometheus"
        # Prometheus runs with --web.external-url=…/prometheus, so the
        # API lives under /prometheus on the same :9090 ClusterIP.
        url       = "http://prometheus.${kubernetes_namespace.prometheus.metadata[0].name}.svc.cluster.local:9090/prometheus"
        access    = "proxy"
        isDefault = true
      }]
    })
  }
}

resource "kubernetes_config_map" "grafana_dashboard_provisioning" {
  metadata {
    name      = "grafana-dashboard-provisioning"
    namespace = kubernetes_namespace.grafana.metadata[0].name
  }
  data = {
    "dashboards.yaml" = yamlencode({
      apiVersion = 1
      providers = [{
        name            = "default"
        orgId           = 1
        folder          = ""
        type            = "file"
        disableDeletion = false
        editable        = true
        options = {
          path = "/var/lib/grafana/dashboards"
        }
      }]
    })
  }
}

resource "kubernetes_config_map" "grafana_nginx_config" {
  metadata {
    name      = "grafana-nginx-config"
    namespace = kubernetes_namespace.grafana.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/grafana.nginx.conf.tpl", {
      server_domain       = "${var.grafana_domain}.${local.magic_fqdn_suffix}"
      nginx_logging_block = local.nginx_logging_blocks["grafana"]
    })
  }
}

resource "kubernetes_deployment" "grafana" {
  metadata {
    name      = "grafana"
    namespace = kubernetes_namespace.grafana.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "grafana" }
    }

    template {
      metadata {
        labels = { app = "grafana" }
        annotations = {
          "datasources-hash"                    = sha1(kubernetes_config_map.grafana_datasources.data["datasources.yaml"])
          "dashboards-hash"                     = sha1(kubernetes_config_map.grafana_dashboard_provisioning.data["dashboards.yaml"])
          "nginx-config-hash"                   = sha1(kubernetes_config_map.grafana_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "${module.grafana_tls_vault.config_secret_name},${module.grafana_tls_vault.tls_secret_name}"
          # Dashboards + datasources are provisioned by services-conf via
          # the Grafana provider; only Grafana's session/user state lives in
          # this PVC. Lost on restore = users re-login, no real loss.
          "backup.velero.io/backup-volumes-excludes" = "grafana-data"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.grafana.metadata[0].name

        # In-cluster reach to Zitadel for OIDC token exchange. Pin
        # oidc.<tailnet> to the Zitadel Service ClusterIP so SNI + LE
        # cert validate without going through a tailscale egress sidecar.
        host_aliases {
          ip        = data.terraform_remote_state.vault_conf.outputs.zitadel_cluster_ip
          hostnames = ["${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"]
        }

        # Wait for Vault CSI secrets
        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
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

        # Fix Grafana data dir ownership (grafana runs as UID 472)
        init_container {
          name  = "fix-permissions"
          image = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            "chown -R 472:472 /var/lib/grafana"
          ]
          volume_mount {
            name       = "grafana-data"
            mount_path = "/var/lib/grafana"
          }
        }

        # Grafana
        container {
          name  = "grafana"
          image = var.image_grafana
          image_pull_policy = "Always"

          port {
            container_port = 3000
            name           = "http"
          }

          env {
            name  = "GF_SERVER_HTTP_PORT"
            value = "3000"
          }
          env {
            name  = "GF_SERVER_ROOT_URL"
            value = "https://${var.grafana_domain}.${local.magic_fqdn_suffix}"
          }
          env {
            name  = "GF_SECURITY_ADMIN_USER"
            value = var.grafana_admin_user
          }
          env {
            name = "GF_SECURITY_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.grafana_tls_vault.config_secret_name
                key  = "admin_password"
              }
            }
          }
          env {
            name  = "GF_USERS_ALLOW_SIGN_UP"
            value = "false"
          }

          # ---- OIDC SSO via Zitadel ----------------------------------
          # Local admin (above) stays as escape hatch. ALLOW_SIGN_UP=true
          # auto-provisions Grafana users on first OIDC login (default
          # role = Viewer; promote via console as needed).
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_ENABLED"
            value = "true"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_NAME"
            value = "Zitadel"
          }
          env {
            name = "GF_AUTH_GENERIC_OAUTH_CLIENT_ID"
            value_from {
              secret_key_ref {
                name = module.grafana_tls_vault.config_secret_name
                key  = "oidc_client_id"
              }
            }
          }
          env {
            name = "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = module.grafana_tls_vault.config_secret_name
                key  = "oidc_client_secret"
              }
            }
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_SCOPES"
            value = "openid profile email"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_AUTH_URL"
            value = "${local.zitadel_issuer_url}/oauth/v2/authorize"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_TOKEN_URL"
            value = "${local.zitadel_issuer_url}/oauth/v2/token"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_API_URL"
            value = "${local.zitadel_issuer_url}/oidc/v1/userinfo"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP"
            value = "true"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_USE_PKCE"
            value = "true"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_LOGIN_ATTRIBUTE_PATH"
            value = "preferred_username"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_EMAIL_ATTRIBUTE_PATH"
            value = "email"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_NAME_ATTRIBUTE_PATH"
            value = "name"
          }
          # JMESPath literal — every OIDC user is Admin. Re-evaluated on
          # every login; STRICT=true means the value enforces, overwriting
          # any console-side role tweaks. TF is source of truth for roles.
          #
          # Why Admin instead of Editor: Grafana 12 has a known bug where
          # Editor returns 403 on the dashboard.grafana.app/v2 unified-storage
          # /dto subresource, so loading a dashboard fails. Bump to Admin
          # until grafana/grafana#121010 ships a fix. For a single-user
          # homelab the practical access is identical.
          # To split roles later (multiple users): JMESPath claim-driven,
          # e.g. contains(groups[*], 'grafana-admin') && 'Admin' || 'Editor'
          # — emit the groups claim from Zitadel.
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH"
            value = "'Admin'"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_STRICT"
            value = "true"
          }

          volume_mount {
            name       = "grafana-data"
            mount_path = "/var/lib/grafana"
          }
          # Empty dir at the path the `file` dashboard provider polls every
          # 30s. Without this, grafana spams `Cannot read directory` ERRORs.
          # Actual dashboards are provisioned via API by the services-conf
          # deployment, not through this path.
          volume_mount {
            name       = "grafana-dashboards-empty"
            mount_path = "/var/lib/grafana/dashboards"
          }
          volume_mount {
            name       = "grafana-datasources"
            mount_path = "/etc/grafana/provisioning/datasources"
          }
          volume_mount {
            name       = "grafana-dashboard-provisioning"
            mount_path = "/etc/grafana/provisioning/dashboards"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            # 512Mi OOM-killed mid-OIDC-login (Grafana 13 unified storage +
            # bleve index + 56 plugins). +2Gi headroom.
            limits = { cpu = "500m", memory = "2560Mi" }
          }

          liveness_probe {
            http_get {
              path = "/api/health"
              port = 3000
            }
            initial_delay_seconds = 60
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/api/health"
              port = 3000
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }
        # Grafana Volumes
        volume {
          name = "grafana-datasources"
          config_map {
            name = kubernetes_config_map.grafana_datasources.metadata[0].name
          }
        }
        volume {
          name = "grafana-dashboard-provisioning"
          config_map {
            name = kubernetes_config_map.grafana_dashboard_provisioning.metadata[0].name
          }
        }
        volume {
          name = "grafana-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.grafana_data.metadata[0].name
          }
        }
        volume {
          name = "grafana-dashboards-empty"
          empty_dir {}
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.grafana_tls_vault.spc_name
            }
          }
        }

        # Nginx
        container {
          name  = "nginx"
          image = var.image_nginx
          image_pull_policy = "Always"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "grafana-tls"
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
          name = "grafana-tls"
          secret { secret_name = module.grafana_tls_vault.tls_secret_name }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.grafana_nginx_config.metadata[0].name
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
            value = module.grafana_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.grafana_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.grafana_domain
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
    module.grafana_tls_vault,
    kubernetes_deployment.prometheus,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

# =============================================================================
# NetworkPolicies for the `grafana` namespace.
#
# Single-pod namespace (grafana + nginx + tailscale sidecars). Cross-ns
# flows this file owns:
#   - egress  grafana → oidc:443 (OIDC sign-in)
#   - egress  grafana → prometheus (prometheus ns) :9090 (datasource)
# =============================================================================

module "grafana_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.grafana.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
  # Tailscale sidecar reaches Headscale + DERP; oauth2 token exchange
  # against Zitadel goes via host_aliases (cross-ns, allowed below).
  allow_internet_egress = true
  # Tailscale sidecar uses TS_KUBE_SECRET to persist state to a k8s Secret.
  allow_kube_api_egress = true
}

# Cross-ns egress: grafana → oidc:443 for the OIDC sign-in flow against
# Zitadel. Mirror ingress lives in services/zitadel-network.tf as
# oidc-from-grafana.
resource "kubernetes_network_policy" "grafana_to_oidc" {
  metadata {
    name      = "grafana-to-oidc"
    namespace = kubernetes_namespace.grafana.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { app = "grafana" }
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

# Cross-ns egress: grafana → prometheus (prometheus ns) :9090.
# Datasource URL is prometheus.prometheus.svc.cluster.local:9090
# (see datasources block above). Mirror ingress lives in
# services/prometheus-network.tf as prometheus-from-grafana.
resource "kubernetes_network_policy" "grafana_to_prometheus" {
  metadata {
    name      = "grafana-to-prometheus"
    namespace = kubernetes_namespace.grafana.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { app = "grafana" }
    }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.prometheus.metadata[0].name
          }
        }
        pod_selector {
          match_labels = { app = "prometheus" }
        }
      }
      ports {
        protocol = "TCP"
        port     = "9090"
      }
    }
  }
}
