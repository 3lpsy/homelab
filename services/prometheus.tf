resource "kubernetes_namespace" "prometheus" {
  metadata {
    name = "prometheus"
  }
}

resource "kubernetes_service_account" "prometheus" {
  metadata {
    name      = "prometheus"
    namespace = kubernetes_namespace.prometheus.metadata[0].name
  }
  # Prometheus needs the token to scrape kubelet/cadvisor
  automount_service_account_token = true
}

resource "kubernetes_cluster_role" "prometheus" {
  metadata { name = "prometheus" }

  rule {
    api_groups = [""]
    resources  = ["nodes", "nodes/proxy", "nodes/metrics", "services", "endpoints", "pods"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["extensions", "networking.k8s.io"]
    resources  = ["ingresses"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    non_resource_urls = ["/metrics", "/metrics/cadvisor"]
    verbs             = ["get"]
  }
}

resource "kubernetes_cluster_role_binding" "prometheus" {
  metadata { name = "prometheus" }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.prometheus.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.prometheus.metadata[0].name
    namespace = kubernetes_namespace.prometheus.metadata[0].name
  }
}

locals {
  prometheus_fqdn = "${var.prometheus_domain}.${local.magic_fqdn_suffix}"
}

# Cookie key for the oauth2-proxy sidecar (32 alphanumeric bytes).
# Rotation forces every signed-in user to re-authenticate.
resource "random_password" "prometheus_oauth2_cookie" {
  length  = 32
  special = false
}

# ─── Zitadel project + role + OIDC application + per-user grant ──────────────
#
# Per memory `feedback_zitadel_one_project_per_service`, prometheus gets its
# own project. project_role_check=true so Zitadel itself rejects token
# issuance for users without a grant — only the personal user can ever
# pass oauth2-proxy.
resource "zitadel_project" "prometheus" {
  name   = "prometheus"
  org_id = data.zitadel_organizations.homelab.ids[0]

  project_role_assertion   = true
  project_role_check       = true
  has_project_check        = true
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"
}

resource "zitadel_project_role" "prometheus_admin" {
  org_id       = data.zitadel_organizations.homelab.ids[0]
  project_id   = zitadel_project.prometheus.id
  role_key     = "admin"
  display_name = "Prometheus admin"
}

resource "zitadel_application_oidc" "prometheus" {
  name       = "Prometheus"
  org_id     = data.zitadel_organizations.homelab.ids[0]
  project_id = zitadel_project.prometheus.id

  redirect_uris             = ["https://${local.prometheus_fqdn}/oauth2/callback"]
  post_logout_redirect_uris = ["https://${local.prometheus_fqdn}/"]

  response_types   = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types      = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"]
  app_type         = "OIDC_APP_TYPE_WEB"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_BASIC"
  dev_mode         = false
}

resource "zitadel_user_grant" "prometheus_personal_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.personal.id
  project_id = zitadel_project.prometheus.id
  role_keys  = [zitadel_project_role.prometheus_admin.role_key]
}

module "prometheus_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "prometheus"
  namespace            = kubernetes_namespace.prometheus.metadata[0].name
  service_account_name = kubernetes_service_account.prometheus.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.prometheus_user
}

# TLS cert + Vault config secret + SPC for the nginx + oauth2-proxy
# sidecars. Lives alongside the alertmanager-ntfy-auth wiring below;
# both SPCs target the same SA via separate Vault auth roles.
module "prometheus_tls_vault" {
  source = "./../templates/service-tls-vault"

  service_name         = "prometheus"
  namespace            = kubernetes_namespace.prometheus.metadata[0].name
  service_account_name = kubernetes_service_account.prometheus.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = local.prometheus_fqdn
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  config_secrets = {
    oidc_client_id       = zitadel_application_oidc.prometheus.client_id
    oidc_client_secret   = zitadel_application_oidc.prometheus.client_secret
    oauth2_cookie_secret = random_password.prometheus_oauth2_cookie.result
  }

  providers = { acme = acme }
}

# Alertmanager reads its ntfy basic-auth password from a file mounted via
# Vault CSI. The password lives in Vault at ntfy/config (key
# password_prometheus, written by the ntfy module). Reloader rotates the
# pod when the synced k8s Secret changes.
resource "vault_policy" "prometheus_alertmanager" {
  name = "prometheus-alertmanager-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/ntfy/config" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "prometheus_alertmanager" {
  backend                          = "kubernetes"
  role_name                        = "prometheus-alertmanager"
  bound_service_account_names      = ["prometheus"]
  bound_service_account_namespaces = ["prometheus"]
  token_policies                   = [vault_policy.prometheus_alertmanager.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "prometheus_alertmanager_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-prometheus-alertmanager"
      namespace = kubernetes_namespace.prometheus.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "prometheus-alertmanager-ntfy-auth"
          type       = "Opaque"
          data = [
            { objectName = "ntfy_password", key = "ntfy_password" },
          ]
        },
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "prometheus-alertmanager"
        objects = yamlencode([
          {
            objectName = "ntfy_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/ntfy/config"
            secretKey  = "password_prometheus"
          },
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.prometheus,
    vault_kubernetes_auth_backend_role.prometheus_alertmanager,
    # Was vault_kv_secret_v2.ntfy_config (now lives inside the
    # ntfy_tls_vault module). Depend on the whole module so the config
    # write completes before this SPC reads from the same path.
    module.ntfy_tls_vault,
    vault_policy.prometheus_alertmanager,
  ]
}

resource "kubernetes_persistent_volume_claim" "prometheus_data" {
  # No prevent_destroy: TSDB blocks are intentionally excluded from FSB
  # (see Deployment annotation `backup.velero.io/backup-volumes-excludes
  # = prometheus-data`) and the deployment annotation comment confirms
  # "Prometheus rebuilds an empty TSDB on restart" — losing this PVC is
  # equivalent to a restart with metric history loss the operator has
  # already opted into.
  metadata {
    name      = "prometheus-data"
    namespace = kubernetes_namespace.prometheus.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.prometheus_storage_size
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_config_map" "prometheus_config" {
  metadata {
    name      = "prometheus-config"
    namespace = kubernetes_namespace.prometheus.metadata[0].name
  }

  data = {
    "prometheus.yml" = templatefile("${path.module}/../data/prometheus/prometheus.yml.tpl", {
      prometheus_target = "localhost:9090"
      alertmanager_target = "localhost:9093"
      # Cross-namespace: prom and ksm each have their own ns, so this
      # must be the FQDN form.
      kube_state_metrics_target = "kube-state-metrics.${kubernetes_namespace.kube_state_metrics.metadata[0].name}.svc.cluster.local:8080"
      openwrt_target            = "${var.openwrt_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}:9100"
    })

    "alert-rules.yml" = file("${path.module}/../data/prometheus/alert-rules.yml.tpl")
  }
}

# nginx + index landing page for the prometheus.<magic> tailnet ingress.
# Two ConfigMaps so the deployment can hash each independently and roll
# only when the relevant content changes.
resource "kubernetes_config_map" "prometheus_nginx_config" {
  metadata {
    name      = "prometheus-nginx-config"
    namespace = kubernetes_namespace.prometheus.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/prometheus.nginx.conf.tpl", {
      server_domain       = local.prometheus_fqdn
      nginx_logging_block = local.nginx_logging_blocks["prometheus"]
    })
  }
}

resource "kubernetes_config_map" "prometheus_index" {
  metadata {
    name      = "prometheus-index"
    namespace = kubernetes_namespace.prometheus.metadata[0].name
  }
  data = {
    "index.html" = file("${path.module}/../data/prometheus/index.html")
  }
}

resource "kubernetes_config_map" "alertmanager_config" {
  metadata {
    name      = "alertmanager-config"
    namespace = kubernetes_namespace.prometheus.metadata[0].name
  }

  # Password is NOT rendered here. alertmanager reads it from
  # /etc/alertmanager-secrets/ntfy_password at startup, mounted via Vault CSI
  # (see vault-prometheus-alertmanager SPC above). Keeps the credential out
  # of the ConfigMap so Velero backups never see it.
  data = {
    "alertmanager.yml" = templatefile("${path.module}/../data/prometheus/alertmanager.yml.tpl", {
      bridge_url    = "http://localhost:8085/alertmanager/pod-state"
      ntfy_username = "prometheus"
    })
  }
}

resource "kubernetes_deployment" "prometheus" {
  metadata {
    name      = "prometheus"
    namespace = kubernetes_namespace.prometheus.metadata[0].name
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = { app = "prometheus" }
    }

    template {
      metadata {
        labels = { app = "prometheus" }
        annotations = {
          "prometheus-config-hash"              = sha1(kubernetes_config_map.prometheus_config.data["prometheus.yml"])
          "alert-rules-hash"                    = sha1(kubernetes_config_map.prometheus_config.data["alert-rules.yml"])
          "alertmanager-config-hash"            = sha1(kubernetes_config_map.alertmanager_config.data["alertmanager.yml"])
          "ntfy-bridge-script-hash"             = sha1(kubernetes_config_map.ntfy_bridge_script.data["ntfy-bridge.py"])
          "nginx-config-hash"                   = sha1(kubernetes_config_map.prometheus_nginx_config.data["nginx.conf"])
          "index-hash"                          = sha1(kubernetes_config_map.prometheus_index.data["index.html"])
          "secret.reloader.stakater.com/reload" = "prometheus-alertmanager-ntfy-auth,${module.prometheus_tls_vault.config_secret_name},${module.prometheus_tls_vault.tls_secret_name}"
          # TSDB blocks are high-churn time-series; restoring stale metrics is
          # rarely useful and the volume bloats Velero. Skip FSB on the data
          # volume — Prometheus rebuilds an empty TSDB on restart.
          "backup.velero.io/backup-volumes-excludes" = "prometheus-data"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.prometheus.metadata[0].name

        # Pin ntfy.<hs>.<magic> to the ntfy Service ClusterIP so the
        # ntfy-bridge sibling container's --ntfy-url (the FQDN form)
        # resolves to the in-cluster nginx :443 instead of going through
        # the prometheus pod's tailscale sidecar. The sidecar itself
        # stays — it advertises `prometheus` for inbound admin UI access.
        host_aliases {
          ip        = kubernetes_service.ntfy.spec[0].cluster_ip
          hostnames = ["${var.ntfy_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"]
        }

        # Pin oidc.<tailnet> to the Zitadel ClusterIP so the oauth2-proxy
        # sidecar reaches Zitadel for SNI/cert validation without an egress
        # Tailscale sidecar (memory: feedback_no_egress_only_ts_sidecars).
        host_aliases {
          ip        = data.terraform_remote_state.vault_conf.outputs.zitadel_cluster_ip
          hostnames = ["${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"]
        }

        # Wait for Vault CSI to materialize the OIDC client credentials
        # before nginx + oauth2-proxy come up; without this the sidecars
        # race the SPC sync and crash-loop on missing env values.
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
            name       = "oauth2-secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        init_container {
          name  = "fix-permissions"
          image = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            "chown -R 65534:65534 /prometheus"
          ]
          volume_mount {
            name       = "prometheus-data"
            mount_path = "/prometheus"
          }
        }

        container {
          name  = "prometheus"
          image = var.image_prometheus
          image_pull_policy = "Always"

          args = [
            "--config.file=/etc/prometheus/prometheus.yml",
            "--storage.tsdb.path=/prometheus",
            "--storage.tsdb.retention.time=${var.prometheus_retention}",
            "--web.enable-lifecycle",
            # Path-prefix mode: nginx fronts both Prometheus and Alertmanager
            # under a single FQDN with /prometheus and /alertmanager paths.
            # Setting --web.external-url with a path also implicitly sets
            # --web.route-prefix to that path, so the server listens under
            # /prometheus internally too. Self-scrape config + Grafana
            # datasource + mcp-prometheus URL all include the prefix.
            "--web.external-url=https://${local.prometheus_fqdn}/prometheus",
            "--log.level=warn",
          ]

          # 9090 stays on 0.0.0.0 (kubelet probes the pod IP from the node;
          # it cannot reach a 127.0.0.1-bound listener inside the pod
          # netns). Direct access is blocked at two layers: tailnet ACL
          # only allows :443 to group:prometheus (see acls_prometheus); the
          # NetworkPolicy baseline default-denies cross-ns ingress, and the
          # only explicit allows on :9090 are grafana + mcp-prometheus.
          port {
            container_port = 9090
            name           = "http"
          }

          volume_mount {
            name       = "prometheus-config"
            mount_path = "/etc/prometheus"
          }
          volume_mount {
            name       = "prometheus-data"
            mount_path = "/prometheus"
          }

          resources {
            requests = { cpu = "250m", memory = "512Mi" }
            limits   = { cpu = "1000m", memory = "2Gi" }
          }

          # Probes ride the new route prefix.
          liveness_probe {
            http_get {
              path = "/prometheus/-/healthy"
              port = 9090
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/prometheus/-/ready"
              port = 9090
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        volume {
          name = "prometheus-config"
          config_map {
            name = kubernetes_config_map.prometheus_config.metadata[0].name
          }
        }
        volume {
          name = "prometheus-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.prometheus_data.metadata[0].name
          }
        }

        container {
          name  = "alertmanager"
          image = var.image_alertmanager
          image_pull_policy = "Always"

          args = [
            "--config.file=/etc/alertmanager/alertmanager.yml",
            "--storage.path=/alertmanager",
            # Same path-prefix story as prometheus — alertmanager serves
            # under /alertmanager so a single nginx + FQDN fronts both UIs.
            "--web.external-url=https://${local.prometheus_fqdn}/alertmanager",
          ]

          port {
            container_port = 9093
            name           = "alertmanager"
          }

          volume_mount {
            name       = "alertmanager-config"
            mount_path = "/etc/alertmanager"
          }
          volume_mount {
            name       = "alertmanager-secrets"
            mount_path = "/etc/alertmanager-secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "250m", memory = "256Mi" }
          }

          liveness_probe {
            http_get {
              path = "/alertmanager/-/healthy"
              port = 9093
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/alertmanager/-/ready"
              port = 9093
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }

        volume {
          name = "alertmanager-config"
          config_map {
            name = kubernetes_config_map.alertmanager_config.metadata[0].name
          }
        }
        volume {
          name = "alertmanager-secrets"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.prometheus_alertmanager_secret_provider.manifest.metadata.name
            }
          }
        }

        container {
          name  = "ntfy-bridge"
          image = var.image_python
          image_pull_policy = "Always"

          command = [
            "python3", "/app/ntfy-bridge.py",
            "--ntfy-url", "https://${var.ntfy_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}",
            "--ntfy-topic", var.ntfy_alert_topic,
            "--port", "8085",
          ]

          port {
            container_port = 8085
            name           = "ntfy-bridge"
          }

          volume_mount {
            name       = "ntfy-bridge-script"
            mount_path = "/app"
            read_only  = true
          }

          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "100m", memory = "64Mi" }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8085
            }
            initial_delay_seconds = 5
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8085
            }
            initial_delay_seconds = 2
            period_seconds        = 10
          }
        }

        volume {
          name = "ntfy-bridge-script"
          config_map {
            name = kubernetes_config_map.ntfy_bridge_script.metadata[0].name
          }
        }

        # ─── Nginx — TLS termination + path routing + landing page ──────────
        # Listens on 443 inside the pod netns; the tailscale sidecar
        # advertises this port to the tailnet. Routes:
        #   /              -> ConfigMap-mounted index.html (auth-gated)
        #   /prometheus/   -> 127.0.0.1:9090 (auth-gated)
        #   /alertmanager/ -> 127.0.0.1:9093 (auth-gated)
        #   /oauth2/*      -> 127.0.0.1:4180 (oauth2-proxy)
        container {
          name  = "nginx"
          image = var.image_nginx
          image_pull_policy = "Always"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "prometheus-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }
          volume_mount {
            name       = "prometheus-index"
            mount_path = "/etc/nginx/html"
            read_only  = true
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        volume {
          name = "prometheus-tls"
          secret { secret_name = module.prometheus_tls_vault.tls_secret_name }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.prometheus_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "prometheus-index"
          config_map {
            name = kubernetes_config_map.prometheus_index.metadata[0].name
          }
        }

        # ─── oauth2-proxy — OIDC code+PKCE against Zitadel ──────────────────
        # Auth-only mode: nginx handles all upstream traffic; oauth2-proxy
        # only answers /oauth2/auth subrequests + the public OIDC dance
        # endpoints. Listens on 127.0.0.1:4180.
        #
        # No groups claim or scope mapping: the prometheus Zitadel project
        # has a single role and access is enforced upstream by Zitadel's
        # project_role_check (only the personal user is granted).
        container {
          name  = "oauth2-proxy"
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
            value = "https://${local.prometheus_fqdn}/oauth2/callback"
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
            value = local.prometheus_fqdn
          }
          env {
            name  = "OAUTH2_PROXY_WHITELIST_DOMAINS"
            value = "${local.prometheus_fqdn},${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"
          }

          env {
            name = "OAUTH2_PROXY_CLIENT_ID"
            value_from {
              secret_key_ref {
                name = module.prometheus_tls_vault.config_secret_name
                key  = "oidc_client_id"
              }
            }
          }
          env {
            name = "OAUTH2_PROXY_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = module.prometheus_tls_vault.config_secret_name
                key  = "oidc_client_secret"
              }
            }
          }
          env {
            name = "OAUTH2_PROXY_COOKIE_SECRET"
            value_from {
              secret_key_ref {
                name = module.prometheus_tls_vault.config_secret_name
                key  = "oauth2_cookie_secret"
              }
            }
          }

          volume_mount {
            name       = "oauth2-secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "20m", memory = "32Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        volume {
          name = "oauth2-secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.prometheus_tls_vault.spc_name
            }
          }
        }

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
            value = module.prometheus_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.prometheus_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = "prometheus"
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

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "prometheus" {
  metadata {
    name      = "prometheus"
    namespace = kubernetes_namespace.prometheus.metadata[0].name
  }

  spec {
    selector = { app = "prometheus" }

    # Cross-ns API consumers (grafana, mcp-prometheus) keep using :9090
    # with the /prometheus path-prefix; netpols restrict who can reach it.
    port {
      name        = "http"
      port        = 9090
      target_port = 9090
    }
    # nginx sidecar — TLS-terminated UI + landing page + alertmanager.
    # In-cluster traffic via this port still works (no host_aliases pin
    # needed), and the tailscale sidecar exposes it to the tailnet on
    # group:prometheus:443.
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
  }
}

# NetworkPolicies for the `prometheus` namespace.
#
# Holds the prometheus + alertmanager + ntfy-bridge pod plus its
# config/secrets — everything else lives elsewhere. Cross-namespace flows
# this file owns:
#   - egress  prometheus → kube-state-metrics (monitoring ns) :8080
#   - egress  ntfy-bridge sidecar → ntfy (ntfy ns) :443
#   - egress  prometheus → host-network targets (node-exporter:9100,
#             kubelet/cadvisor:10250) via ipBlock
#   - ingress mcp-prometheus (mcp ns) → prometheus :9090
#   - ingress grafana (monitoring ns) → prometheus :9090

module "prometheus_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.prometheus.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
  # Prometheus tailscale sidecar reaches Headscale + DERP for inbound admin
  # UI access; ntfy-bridge sidecar reaches the ntfy ClusterIP via
  # host_aliases (cross-ns, allowed via the explicit egress below).
  allow_internet_egress = true
  # ServiceAccount token used to scrape kubelet/cadvisor.
  allow_kube_api_egress = true
}

# Cross-ns egress: oauth2-proxy sidecar (in the prometheus pod) → oidc:443
# for the OIDC code+PKCE flow (discovery, JWKS, token exchange, userinfo).
# Mirror ingress lives in services/zitadel-network.tf as oidc-from-prometheus.
resource "kubernetes_network_policy" "prometheus_to_oidc" {
  metadata {
    name      = "prometheus-to-oidc"
    namespace = kubernetes_namespace.prometheus.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = { app = "prometheus" }
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

# Cross-ns egress: ntfy-bridge sidecar (in the prometheus pod) → ntfy:443.
# The bridge resolves `ntfy.<hs>.<magic>` via host_aliases (pinned to the
# ntfy Service ClusterIP in the ntfy ns) so SNI carries the FQDN and the
# Let's Encrypt cert validates without a tailscale hop.
# Mirror ingress lives in services/ntfy-network.tf as ntfy-from-prometheus.
resource "kubernetes_network_policy" "prometheus_to_ntfy" {
  metadata {
    name      = "prometheus-to-ntfy"
    namespace = kubernetes_namespace.prometheus.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { app = "prometheus" }
    }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.ntfy.metadata[0].name
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

# Cross-ns egress: prometheus → kube-state-metrics:8080 in monitoring ns.
# kube-state-metrics is a scrape target referenced by FQDN in the rendered
# prometheus.yml.
# Mirror ingress lives in services/monitoring-network.tf as
# kube-state-metrics-from-prometheus.
resource "kubernetes_network_policy" "prometheus_to_kube_state_metrics" {
  metadata {
    name      = "prometheus-to-kube-state-metrics"
    namespace = kubernetes_namespace.prometheus.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { app = "prometheus" }
    }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.kube_state_metrics.metadata[0].name
          }
        }
        pod_selector {
          match_labels = {
            app = "kube-state-metrics"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "8080"
      }
    }
  }
}

# Cross-ns egress: prometheus → amd-gpu-metrics-exporter:5000 in the amd-gpu
# ns. The exporter is an annotated pod picked up by the `kubernetes-pods`
# scrape job; pod-CIDR egress is default-denied (the host-target rule below
# excludes the pod+service CIDR), so this explicit allow is required.
# Mirror ingress lives in services/amd-gpu-metrics-exporter.tf as
# `gpu-metrics-from-prometheus`.
resource "kubernetes_network_policy" "prometheus_to_gpu_metrics" {
  metadata {
    name      = "prometheus-to-gpu-metrics"
    namespace = kubernetes_namespace.prometheus.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { app = "prometheus" }
    }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.amd_gpu.metadata[0].name
          }
        }
        pod_selector {
          match_labels = {
            app = "amd-gpu-metrics-exporter"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "5000"
      }
    }
  }
}

# Egress to host-network scrape targets (node-exporter:9100, kubelet+
# cadvisor:10250). Both run on the K3s node's host network, so their
# endpoint IP is the node IP — outside the cluster CIDRs and only
# reachable via ipBlock allow.
resource "kubernetes_network_policy" "prometheus_scrape_host_targets" {
  metadata {
    name      = "prometheus-scrape-host-targets"
    namespace = kubernetes_namespace.prometheus.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { app = "prometheus" }
    }
    policy_types = ["Egress"]

    egress {
      to {
        ip_block {
          cidr = "0.0.0.0/0"
          except = [
            var.k8s_pod_cidr,
            var.k8s_service_cidr,
          ]
        }
      }
      ports {
        protocol = "TCP"
        port     = "9100"
      }
      ports {
        protocol = "TCP"
        port     = "10250"
      }
    }
  }
}

# Cross-ns ingress: mcp-prometheus (mcp ns) → prometheus:9090.
# Mirror of services/mcp-prometheus.tf:`mcp_prometheus_to_prometheus`.
resource "kubernetes_network_policy" "prometheus_from_mcp_prometheus" {
  metadata {
    name      = "prometheus-from-mcp-prometheus"
    namespace = kubernetes_namespace.prometheus.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { app = "prometheus" }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.mcp.metadata[0].name
          }
        }
        pod_selector {
          match_labels = { app = "mcp-prometheus" }
        }
      }
      ports {
        protocol = "TCP"
        port     = "9090"
      }
    }
  }
}

# Cross-ns ingress: grafana (monitoring ns) → prometheus:9090.
# Grafana's Prometheus datasource URL is the prometheus.<ns>.svc form
# (see grafana.tf datasources block).
resource "kubernetes_network_policy" "prometheus_from_grafana" {
  metadata {
    name      = "prometheus-from-grafana"
    namespace = kubernetes_namespace.prometheus.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { app = "prometheus" }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.grafana.metadata[0].name
          }
        }
        pod_selector {
          match_labels = { app = "grafana" }
        }
      }
      ports {
        protocol = "TCP"
        port     = "9090"
      }
    }
  }
}
