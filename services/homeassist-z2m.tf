# zigbee2mqtt frontend + nginx TLS terminator + tailscale sidecar.
#
# Z2M reuses homeassist's headscale pre-auth key (both pods share the
# `homeassist` tailnet user, registering as separate devices `homeassist`
# and `z2m`). That means tailscale-ingress doesn't fit cleanly here — the
# module always creates its own pre-auth key + auth Secret. State Secret
# + Role + RoleBinding stay hand-rolled below.
#
# Vault auth: shared `vault_policy.homeassist` (declared in homeassist.tf).
# This file owns the per-service auth role; tls_vault module call uses
# manage_vault_auth=false.

resource "kubernetes_service_account" "homeassist_z2m" {
  metadata {
    name      = "homeassist-z2m"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_secret" "homeassist_z2m_tailscale_state" {
  metadata {
    name      = "homeassist-z2m-tailscale-state"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  type = "Opaque"

  lifecycle {
    ignore_changes = [data, type]
  }
}

resource "kubernetes_role" "homeassist_z2m_tailscale" {
  metadata {
    name      = "homeassist-z2m-tailscale"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["homeassist-z2m-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "homeassist_z2m_tailscale" {
  metadata {
    name      = "homeassist-z2m-tailscale"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.homeassist_z2m_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.homeassist_z2m.metadata[0].name
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
}

# Cookie key for the oauth2-proxy sidecar (32 alphanumeric bytes).
# Rotation forces every signed-in user to re-authenticate.
resource "random_password" "homeassist_z2m_oauth2_cookie" {
  length  = 32
  special = false
}

# ─── Zitadel project + role + OIDC application + per-user grant ─────────────
#
# Per memory feedback_zitadel_one_project_per_service, z2m gets its own
# project. project_role_check=true so Zitadel itself rejects token issuance
# for users without a grant — only the personal user can ever sign in.
resource "zitadel_project" "homeassist_z2m" {
  name   = "homeassist-z2m"
  org_id = data.zitadel_organizations.homelab.ids[0]

  project_role_assertion   = true
  project_role_check       = true
  has_project_check        = true
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"
}

resource "zitadel_project_role" "homeassist_z2m_admin" {
  org_id       = data.zitadel_organizations.homelab.ids[0]
  project_id   = zitadel_project.homeassist_z2m.id
  role_key     = "admin"
  display_name = "Zigbee2MQTT admin"
}

resource "zitadel_application_oidc" "homeassist_z2m" {
  name       = "Zigbee2MQTT"
  org_id     = data.zitadel_organizations.homelab.ids[0]
  project_id = zitadel_project.homeassist_z2m.id

  redirect_uris             = ["https://${var.homeassist_z2m_domain}.${local.magic_fqdn_suffix}/oauth2/callback"]
  post_logout_redirect_uris = ["https://${var.homeassist_z2m_domain}.${local.magic_fqdn_suffix}/"]

  response_types   = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types      = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"]
  app_type         = "OIDC_APP_TYPE_WEB"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_BASIC"
  dev_mode         = false
}

resource "zitadel_user_grant" "homeassist_z2m_personal_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.personal.id
  project_id = zitadel_project.homeassist_z2m.id
  role_keys  = [zitadel_project_role.homeassist_z2m_admin.role_key]
}

resource "vault_kubernetes_auth_backend_role" "homeassist_z2m" {
  backend                          = "kubernetes"
  role_name                        = "homeassist-z2m"
  bound_service_account_names      = ["homeassist-z2m"]
  bound_service_account_namespaces = ["homeassist"]
  token_policies                   = [vault_policy.homeassist.name]
  token_ttl                        = 86400
}

module "homeassist_z2m_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "homeassist-z2m"
  namespace            = kubernetes_namespace.homeassist.metadata[0].name
  service_account_name = kubernetes_service_account.homeassist_z2m.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = "${var.homeassist_z2m_domain}.${local.magic_fqdn_suffix}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  # Vault path uses a slash separator (homeassist/z2m/config, /tls)
  # rather than the default homeassist-z2m/*. Keeps the homeassist
  # subtree contiguous and matches the existing path layout.
  vault_kv_path = "homeassist/z2m"

  config_secrets = {
    oidc_client_id       = zitadel_application_oidc.homeassist_z2m.client_id
    oidc_client_secret   = zitadel_application_oidc.homeassist_z2m.client_secret
    oauth2_cookie_secret = random_password.homeassist_z2m_oauth2_cookie.result
  }

  extra_config_keys = [
    {
      object_name = "z2m_password"
      vault_path  = "homeassist/mosquitto"
      vault_key   = "z2m_password"
    }
  ]

  manage_vault_auth = false
  role_name         = vault_kubernetes_auth_backend_role.homeassist_z2m.role_name

  providers = { acme = acme }

  depends_on = [vault_kv_secret_v2.homeassist_mosquitto]
}

resource "kubernetes_persistent_volume_claim" "homeassist_z2m_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "homeassist-z2m-data"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = "5Gi"
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_config_map" "homeassist_z2m_config" {
  metadata {
    name      = "homeassist-z2m-config"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  data = {
    # First-boot seed; user-owned thereafter (Z2M frontend writes devices /
    # groups / friendly-names here). All TF-managed `mqtt.*` and `serial.*`
    # values come in via `ZIGBEE2MQTT_CONFIG_*` env vars on the main
    # container — Z2M overrides any matching key in configuration.yaml with
    # the env value at runtime, never persisting the override to disk. This
    # sidesteps Z2M's schema migrations rewriting `!include` / `!secret`
    # references (issues #27077, #21803, #27696). `version: 5` matches Z2M's
    # current settings schema so migrations are a no-op on first load.
    "configuration.yaml" = <<-EOT
      version: 5

      homeassistant:
        enabled: true

      frontend:
        enabled: true
        host: 127.0.0.1
        port: 8080

      advanced:
        log_level: info
        log_output:
          - console
        cache_state: true
        cache_state_persistent: true

      availability:
        enabled: true
        active:
          timeout: 10
        passive:
          timeout: 1500
    EOT
  }
}

resource "kubernetes_config_map" "homeassist_z2m_nginx_config" {
  metadata {
    name      = "homeassist-z2m-nginx-config"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/homeassist-z2m.nginx.conf.tpl", {
      server_domain       = "${var.homeassist_z2m_domain}.${local.magic_fqdn_suffix}"
      nginx_logging_block = local.nginx_logging_blocks["homeassist-z2m"]
    })
  }
}

resource "kubernetes_deployment" "homeassist_z2m" {
  metadata {
    name      = "homeassist-z2m"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "homeassist-z2m" }
    }

    template {
      metadata {
        labels = { app = "homeassist-z2m" }
        annotations = {
          "config-hash"                         = sha1(kubernetes_config_map.homeassist_z2m_config.data["configuration.yaml"])
          "nginx-config-hash"                   = sha1(kubernetes_config_map.homeassist_z2m_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "${module.homeassist_z2m_tls_vault.config_secret_name},${module.homeassist_z2m_tls_vault.tls_secret_name}"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.homeassist_z2m.metadata[0].name

        # Pin oidc.<tailnet> to the Zitadel ClusterIP so the oauth2-proxy
        # sidecar reaches Zitadel for SNI/cert validation without an egress
        # Tailscale sidecar (memory: feedback_no_egress_only_ts_sidecars).
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
              secret_file = "oidc_client_id"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # First boot only: seeds configuration.yaml on the PVC. User-owned
        # thereafter (Z2M frontend writes devices / groups / friendly-names
        # here). All TF-managed mqtt.* and serial.* values come in via
        # ZIGBEE2MQTT_CONFIG_* env vars on the main container, so the init
        # never has to touch configuration.yaml after the seed.
        init_container {
          name  = "seed-z2m-config"
          image = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            <<-EOT
              set -e
              if [ ! -f /app/data/configuration.yaml ]; then
                cp /etc/z2m-config-seed/configuration.yaml /app/data/configuration.yaml
              fi
            EOT
          ]
          volume_mount {
            name       = "z2m-data"
            mount_path = "/app/data"
          }
          volume_mount {
            name       = "z2m-config-seed"
            mount_path = "/etc/z2m-config-seed"
            read_only  = true
          }
        }

        # Zigbee2MQTT
        container {
          name  = "z2m"
          image = var.image_homeassist_z2m
          image_pull_policy = "Always"

          port {
            container_port = 8080
            name           = "http"
          }

          env {
            name  = "TZ"
            value = var.homeassist_time_zone
          }
          env {
            name  = "ZIGBEE2MQTT_DATA"
            value = "/app/data"
          }
          # ZIGBEE2MQTT_CONFIG_* env vars override the matching keys in
          # configuration.yaml at runtime, never persist to disk, and survive
          # Z2M's schema migrations. Source of truth for all TF-managed
          # broker / serial settings.
          env {
            name  = "ZIGBEE2MQTT_CONFIG_MQTT_SERVER"
            value = "mqtt://mosquitto.homeassist.svc.cluster.local:1883"
          }
          env {
            name  = "ZIGBEE2MQTT_CONFIG_MQTT_USER"
            value = "z2m"
          }
          env {
            name = "ZIGBEE2MQTT_CONFIG_MQTT_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.homeassist_z2m_tls_vault.config_secret_name
                key  = "z2m_password"
              }
            }
          }
          # serial.* envs only when the dongle is actually wired in. Without
          # them Z2M crash-loops with "no coordinator", which is the visible
          # signal that var.homeassist_z2m_usb_device_path is unset.
          dynamic "env" {
            for_each = var.homeassist_z2m_usb_device_path != "" ? [1] : []
            content {
              name  = "ZIGBEE2MQTT_CONFIG_SERIAL_PORT"
              value = "/dev/zigbee"
            }
          }
          dynamic "env" {
            for_each = var.homeassist_z2m_usb_device_path != "" ? [1] : []
            content {
              name  = "ZIGBEE2MQTT_CONFIG_SERIAL_ADAPTER"
              value = "ember"
            }
          }
          # ZBT-2 requires hardware flow control. Z2M defaults serial.rtscts
          # to false and falls back to software flow control (XON/XOFF),
          # which the ZBT-2's EmberZNet firmware does not speak — ASH
          # handshake then fails with HOST_FATAL_ERROR after a few retries.
          # Hard-on it whenever the dongle is wired in.
          dynamic "env" {
            for_each = var.homeassist_z2m_usb_device_path != "" ? [1] : []
            content {
              name  = "ZIGBEE2MQTT_CONFIG_SERIAL_RTSCTS"
              value = "true"
            }
          }
          # ZBT-2's EmberZNet NCP firmware runs at 460800. Z2M's ember
          # adapter defaults to 115200 — mismatch produces an ASH-reset loop
          # at startup even with rtscts on.
          dynamic "env" {
            for_each = var.homeassist_z2m_usb_device_path != "" ? [1] : []
            content {
              name  = "ZIGBEE2MQTT_CONFIG_SERIAL_BAUDRATE"
              value = "460800"
            }
          }

          volume_mount {
            name       = "z2m-data"
            mount_path = "/app/data"
          }
          # secrets-store mount kept so syncSecret keeps homeassist-z2m-secrets
          # populated for the env-var secretKeyRef above and for the nginx
          # sidecar's basic-auth + TLS.
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          # USB coordinator passthrough. Active only when
          # var.homeassist_z2m_usb_device_path is set.
          dynamic "volume_mount" {
            for_each = var.homeassist_z2m_usb_device_path != "" ? [1] : []
            content {
              name       = "zigbee-usb"
              mount_path = "/dev/zigbee"
            }
          }

          # privileged is required for char-device access via hostPath. Gated
          # on the USB var so the pod only escalates when actually needed.
          dynamic "security_context" {
            for_each = var.homeassist_z2m_usb_device_path != "" ? [1] : []
            content {
              privileged = true
            }
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1000m", memory = "1Gi" }
          }

          # Z2M's frontend binds 127.0.0.1:8080 (nginx-sidecar-only). A k8s
          # tcp_socket probe targets the pod IP, not loopback, so it always
          # fails. Exec the check inside the container instead.
          liveness_probe {
            exec {
              command = ["sh", "-c", "nc -z 127.0.0.1 8080"]
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            timeout_seconds       = 10
            failure_threshold     = 5
          }

          readiness_probe {
            exec {
              command = ["sh", "-c", "nc -z 127.0.0.1 8080"]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        # Z2M Volumes
        volume {
          name = "z2m-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.homeassist_z2m_data.metadata[0].name
          }
        }
        volume {
          name = "z2m-config-seed"
          config_map {
            name = kubernetes_config_map.homeassist_z2m_config.metadata[0].name
          }
        }

        dynamic "volume" {
          for_each = var.homeassist_z2m_usb_device_path != "" ? [1] : []
          content {
            name = "zigbee-usb"
            host_path {
              path = var.homeassist_z2m_usb_device_path
              type = "CharDevice"
            }
          }
        }

        # Nginx
        container {
          name  = "homeassist-z2m-nginx"
          image = var.image_nginx
          image_pull_policy = "Always"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "homeassist-z2m-tls"
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
          name = "homeassist-z2m-tls"
          secret { secret_name = module.homeassist_z2m_tls_vault.tls_secret_name }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.homeassist_z2m_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.homeassist_z2m_tls_vault.spc_name
            }
          }
        }

        # ─── oauth2-proxy — OIDC code+PKCE against Zitadel ─────────────────
        # Auth-only mode: nginx handles upstream traffic; oauth2-proxy only
        # answers /oauth2/auth subrequests + the public OIDC dance endpoints.
        # Listens on 127.0.0.1:4180.
        #
        # No groups claim: project has a single role and access is enforced
        # upstream by Zitadel's project_role_check (only the personal user
        # is granted on this project).
        container {
          name  = "homeassist-z2m-oauth2-proxy"
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
            value = "https://${var.homeassist_z2m_domain}.${local.magic_fqdn_suffix}/oauth2/callback"
          }
          env {
            name  = "OAUTH2_PROXY_HTTP_ADDRESS"
            value = "127.0.0.1:4180"
          }
          env {
            name  = "OAUTH2_PROXY_REVERSE_PROXY"
            value = "true"
          }
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
            value = "${var.homeassist_z2m_domain}.${local.magic_fqdn_suffix}"
          }
          env {
            name  = "OAUTH2_PROXY_WHITELIST_DOMAINS"
            value = "${var.homeassist_z2m_domain}.${local.magic_fqdn_suffix},${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"
          }

          env {
            name = "OAUTH2_PROXY_CLIENT_ID"
            value_from {
              secret_key_ref {
                name = module.homeassist_z2m_tls_vault.config_secret_name
                key  = "oidc_client_id"
              }
            }
          }
          env {
            name = "OAUTH2_PROXY_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = module.homeassist_z2m_tls_vault.config_secret_name
                key  = "oidc_client_secret"
              }
            }
          }
          env {
            name = "OAUTH2_PROXY_COOKIE_SECRET"
            value_from {
              secret_key_ref {
                name = module.homeassist_z2m_tls_vault.config_secret_name
                key  = "oauth2_cookie_secret"
              }
            }
          }

          resources {
            requests = { cpu = "20m", memory = "32Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        # Tailscale (reuses existing homeassist-tailscale-auth Secret since
        # the pre-auth key is reusable and both pods are owned by the same
        # homeassist tailnet user — they appear as separate devices `homeassist`
        # and `z2m` under that user, both covered by group:homeassist-server
        # ACLs.)
        container {
          name  = "homeassist-z2m-tailscale"
          image = var.image_tailscale
          image_pull_policy = "Always"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "homeassist-z2m-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.homeassist_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.homeassist_z2m_domain
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
    module.homeassist_z2m_tls_vault,
    kubernetes_deployment.homeassist_mosquitto,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

# Cross-ns egress: oauth2-proxy sidecar (in the homeassist-z2m pod) →
# oidc:443 for the OIDC code+PKCE flow. Pod-scoped per memory
# feedback_netpol_least_privilege; sibling homeassist pod has its own
# (homeassist_to_oidc) since label selectors don't overlap.
# Mirror ingress lives in services/zitadel-network.tf as
# oidc-from-homeassist-z2m.
resource "kubernetes_network_policy" "homeassist_z2m_to_oidc" {
  metadata {
    name      = "homeassist-z2m-to-oidc"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = { app = "homeassist-z2m" }
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
