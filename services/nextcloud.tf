# Shared namespace resources (serves nextcloud, immich, shared postgres + redis)

resource "kubernetes_namespace" "nextcloud" {
  metadata {
    name = "nextcloud"
  }
}

resource "kubernetes_service_account" "nextcloud" {
  metadata {
    name      = "nextcloud"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_secret" "registry_pull_secret" {
  metadata {
    name      = "registry-pull-secret"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
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

# Nextcloud secrets

resource "random_password" "nextcloud_admin" {
  length  = 32
  special = true
}

resource "random_password" "postgres_password" {
  length  = 32
  special = false
}

resource "random_password" "redis_password" {
  length  = 32
  special = false
}

module "nextcloud_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "nextcloud"
  namespace            = kubernetes_namespace.nextcloud.metadata[0].name
  service_account_name = kubernetes_service_account.nextcloud.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.nextcloud_server_user

  # Preserve the bare K8s names from the pre-module shape so moved{} renames
  # state addresses in place without forcing a destroy/recreate of the
  # underlying K8s objects (metadata.name is ForceNew on Secrets/Roles).
  # tailscale-state is the critical one — recreating it would lose the
  # tailscaled device identity and force a TS_AUTHKEY re-register.
  role_name         = "tailscale"
  state_secret_name = "tailscale-state"
  auth_secret_name  = "tailscale-auth"

  # Preserve the existing 1y key TTL. The 3y default applies on rotation.
  time_to_expire = "1y"
}

module "nextcloud_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "nextcloud"
  namespace            = kubernetes_namespace.nextcloud.metadata[0].name
  service_account_name = kubernetes_service_account.nextcloud.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = "${var.nextcloud_domain}.${local.magic_fqdn_suffix}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  config_secrets = {
    admin_password    = random_password.nextcloud_admin.result
    postgres_password = random_password.postgres_password.result
    redis_password    = random_password.redis_password.result
    # Consumed by the configure-oidc Job (services/nextcloud-jobs.tf), which
    # passes them to `occ user_oidc:provider zitadel`. Rotation flows through
    # CSI without re-rendering: the Job re-runs on every apply and reads from
    # /mnt/secrets at runtime.
    oidc_client_id     = zitadel_application_oidc.nextcloud.client_id
    oidc_client_secret = zitadel_application_oidc.nextcloud.client_secret
  }

  providers = { acme = acme }
}

resource "kubernetes_persistent_volume_claim" "nextcloud_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "nextcloud-data"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"

    resources {
      requests = {
        storage = "50Gi"
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_persistent_volume_claim" "nextcloud_postgres_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "postgres-data"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"

    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_config_map" "nginx_config" {
  metadata {
    name      = "nginx-config"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/nextcloud.nginx.conf.tpl", {
      server_domain       = "${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
      nginx_logging_block = local.nginx_logging_blocks["nextcloud"]
    })
  }
}

# NetworkPolicies for the `nextcloud` namespace.
#
# The namespace hosts: nextcloud, immich (server + ML + postgres + redis),
# shared postgres, shared redis. The default-deny baseline below allows all
# of them to talk to each other freely (intra-ns), reach the K8s API
# (Tailscale sidecars manage their own state Secrets), and egress to the
# internet (Tailscale Headscale + DERP, ML model downloads, etc).
#
# Cross-ns WOPI loop with collabora rides host_aliases pinning the peer
# FQDN to the peer's *-internal ClusterIP, so SNI matches the public cert
# without traversing the Tailscale sidecar.

module "nextcloud_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.nextcloud.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
  # internet + K8s API egress on (defaults). Both required: Tailscale
  # sidecars need internet for Headscale/DERP and the K8s API for
  # TS_KUBE_SECRET state.
}

# Ingress on nextcloud-nginx:443 from the collabora pod (WOPI callbacks).
resource "kubernetes_network_policy" "nextcloud_from_collabora" {
  metadata {
    name      = "nextcloud-from-collabora"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "nextcloud"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.collabora.metadata[0].name
          }
        }
        pod_selector {
          match_labels = {
            app = "collabora"
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

# Cross-ns egress: nextcloud → oidc:443 for the user_oidc app's discovery,
# JWKS, token, and userinfo round-trips. Mirror ingress lives in
# services/zitadel-network.tf as oidc-from-nextcloud. Pod-scoped per memory
# feedback_netpol_least_privilege; covers both the main Deployment
# (`app = nextcloud`) and the configure-oidc Job
# (`app = nextcloud-configure-oidc`). The Job pod uses a distinct label so
# the nextcloud Service selector does not include it as an endpoint.
resource "kubernetes_network_policy" "nextcloud_to_oidc" {
  metadata {
    name      = "nextcloud-to-oidc"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  spec {
    pod_selector {
      match_expressions {
        key      = "app"
        operator = "In"
        values   = ["nextcloud", "nextcloud-configure-oidc"]
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

# Egress from the nextcloud pod to collabora-nginx:443.
resource "kubernetes_network_policy" "nextcloud_to_collabora" {
  metadata {
    name      = "nextcloud-to-collabora"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "nextcloud"
      }
    }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.collabora.metadata[0].name
          }
        }
        pod_selector {
          match_labels = {
            app = "collabora"
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

resource "kubernetes_deployment" "nextcloud" {
  metadata {
    name      = "nextcloud"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        app = "nextcloud"
      }
    }

    template {
      metadata {
        labels = {
          app = "nextcloud"
        }
        annotations = {
          "build-job"                           = module.nextcloud_build.job_name
          "nginx-config-hash"                   = sha1(kubernetes_config_map.nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "nextcloud-secrets,nextcloud-tls"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name
        image_pull_secrets {
          name = kubernetes_secret.registry_pull_secret.metadata[0].name
        }
        host_aliases {
          ip = kubernetes_service.collabora_internal.spec[0].cluster_ip
          hostnames = [
            "${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          ]
        }

        # Pin oidc.<tailnet> to the in-cluster Zitadel ClusterIP. user_oidc
        # fetches the discovery doc + JWKS + userinfo on every login; SNI
        # carries the FQDN so the LE cert validates against the ClusterIP,
        # no Tailscale egress sidecar needed. Mirrors the homeassist /
        # rustical / audiobookshelf pattern.
        host_aliases {
          ip = data.terraform_remote_state.vault_conf.outputs.zitadel_cluster_ip
          hostnames = [
            "${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          ]
        }

        # Nextcloud
        container {
          name  = "nextcloud"
          image = local.nextcloud_image
          image_pull_policy = "Always"

          port {
            container_port = 80
          }

          env {
            name  = "POSTGRES_HOST"
            value = "postgres"
          }

          env {
            name  = "POSTGRES_DB"
            value = "nextcloud"
          }

          env {
            name  = "POSTGRES_USER"
            value = "nextcloud"
          }

          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.nextcloud_tls_vault.config_secret_name
                key  = "postgres_password"
              }
            }
          }

          env {
            name  = "REDIS_HOST"
            value = "redis"
          }

          env {
            name = "REDIS_HOST_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.nextcloud_tls_vault.config_secret_name
                key  = "redis_password"
              }
            }
          }

          env {
            name  = "REDIS_HOST_PORT"
            value = "6379"
          }

          env {
            name  = "NEXTCLOUD_ADMIN_USER"
            value = var.nextcloud_admin_user
          }

          env {
            name = "NEXTCLOUD_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.nextcloud_tls_vault.config_secret_name
                key  = "admin_password"
              }
            }
          }

          env {
            name  = "NEXTCLOUD_CSP_ALLOWED_DOMAINS"
            value = "${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }

          env {
            name  = "NEXTCLOUD_TRUSTED_DOMAINS"
            value = "${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }

          env {
            name  = "OVERWRITEPROTOCOL"
            value = "https"
          }

          env {
            name  = "OVERWRITEHOST"
            value = "${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }

          env {
            name  = "OVERWRITECLIURL"
            value = "https://${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }

          env {
            name  = "TRUSTED_PROXIES"
            value = "127.0.0.1 ::1 10.42.0.0/16 10.43.0.0/16"
          }

          volume_mount {
            name       = "nextcloud-data"
            mount_path = "/var/www/html"
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "500m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "4000m"
              memory = "4Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/status.php"
              port = 80
              http_header {
                name  = "Host"
                value = "${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
              }
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }

          readiness_probe {
            http_get {
              path = "/status.php"
              port = 80
              http_header {
                name  = "Host"
                value = "${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
              }
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 3
            failure_threshold     = 30
          }
        }

        # Nextcloud Volumes
        volume {
          name = "nextcloud-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.nextcloud_data.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.nextcloud_tls_vault.spc_name
            }
          }
        }

        # Nginx
        container {
          name  = "nextcloud-nginx"
          image = var.image_nginx
          image_pull_policy = "Always"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "nextcloud-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }

          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "2000m"
              memory = "2Gi"
            }
          }
        }

        # Nginx Volumes
        volume {
          name = "nextcloud-tls"
          secret {
            secret_name = module.nextcloud_tls_vault.tls_secret_name
          }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.nginx_config.metadata[0].name
          }
        }

        # Tailscale
        container {
          name  = "nextcloud-tailscale"
          image = var.image_tailscale
          image_pull_policy = "Always"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }

          env {
            name  = "TS_KUBE_SECRET"
            value = module.nextcloud_tailscale.state_secret_name
          }

          env {
            name  = "TS_USERSPACE"
            value = "false"
          }

          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.nextcloud_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }

          env {
            name  = "TS_HOSTNAME"
            value = var.nextcloud_domain
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
    module.nextcloud_tls_vault,
    kubernetes_service.nextcloud_postgres,
    kubernetes_service.nextcloud_redis,
    module.nextcloud_build,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "nextcloud_internal" {
  metadata {
    name      = "nextcloud-internal"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    selector = {
      app = "nextcloud"
    }

    port {
      name        = "https"
      port        = 443
      target_port = 443
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_deployment" "nextcloud_postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "postgres"
      }
    }

    template {
      metadata {
        labels = {
          app = "postgres"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name

        container {
          name  = "postgres"
          image = var.image_postgres
          image_pull_policy = "Always"

          env {
            name  = "POSTGRES_DB"
            value = "nextcloud"
          }

          env {
            name  = "POSTGRES_USER"
            value = "nextcloud"
          }

          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.nextcloud_tls_vault.config_secret_name
                key  = "postgres_password"
              }
            }
          }

          port {
            container_port = 5432
          }

          volume_mount {
            name       = "postgres-data"
            mount_path = "/var/lib/postgresql/data"
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }

          liveness_probe {
            exec {
              command = ["pg_isready", "-U", "nextcloud"]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          readiness_probe {
            exec {
              command = ["pg_isready", "-U", "nextcloud"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }

        volume {
          name = "postgres-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.nextcloud_postgres_data.metadata[0].name
          }
        }

        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.nextcloud_tls_vault.spc_name
            }
          }
        }
      }
    }
  }

  depends_on = [
    module.nextcloud_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "nextcloud_postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    selector = {
      app = "postgres"
    }

    port {
      port        = 5432
      target_port = 5432
    }
  }
}

resource "kubernetes_deployment" "nextcloud_redis" {
  metadata {
    name      = "redis"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "redis"
      }
    }

    template {
      metadata {
        labels = {
          app = "redis"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name

        container {
          name  = "redis"
          image = var.image_redis
          image_pull_policy = "Always"

          command = [
            "redis-server",
            "--requirepass",
            "$(REDIS_PASSWORD)"
          ]

          env {
            name = "REDIS_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.nextcloud_tls_vault.config_secret_name
                key  = "redis_password"
              }
            }
          }

          port {
            container_port = 6379
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          liveness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          readiness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }

        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.nextcloud_tls_vault.spc_name
            }
          }
        }
      }
    }
  }

  depends_on = [
    module.nextcloud_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "nextcloud_redis" {
  metadata {
    name      = "redis"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    selector = {
      app = "redis"
    }

    port {
      port        = 6379
      target_port = 6379
    }
  }
}

# ─── Zitadel project + OIDC application + per-user grant ─────────────────────
#
# Per memory `feedback_zitadel_one_project_per_service`, each service gets its
# own project. The configure-oidc Job in services/nextcloud-jobs.tf reconciles
# the user_oidc app's provider config to these values via `occ user_oidc:provider`.
resource "zitadel_project" "nextcloud" {
  name   = "nextcloud"
  org_id = data.zitadel_organizations.homelab.ids[0]

  project_role_assertion   = false
  project_role_check       = false
  has_project_check        = false
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"
}

resource "zitadel_application_oidc" "nextcloud" {
  name       = "Nextcloud"
  org_id     = data.zitadel_organizations.homelab.ids[0]
  project_id = zitadel_project.nextcloud.id

  # user_oidc's web callback path is hardcoded; constructed from
  # X-Forwarded-Proto + X-Forwarded-Host (already set by the nginx sidecar).
  redirect_uris = [
    "https://${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}/apps/user_oidc/code",
  ]
  # user_oidc builds the post-logout URI from `urlGenerator->getAbsoluteURL('/')`
  # which yields the trailing-slash form. Register both for safety against any
  # normalization quirks (echoing the lesson from ABS's logout URI mismatch).
  post_logout_redirect_uris = [
    "https://${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}/",
    "https://${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}",
  ]

  response_types   = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types      = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"]
  app_type         = "OIDC_APP_TYPE_WEB"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_BASIC"
  dev_mode         = false
}

# Grant for the personal Zitadel user. Mirrors the sibling-service pattern —
# project_role_check is off so the grant is currently a no-op for authz, but
# it's pre-positioned for the day we flip enforcement on. Auto-register
# remains disabled at the user_oidc level so no other Zitadel-org user can
# mint a Nextcloud account regardless.
resource "zitadel_user_grant" "nextcloud_personal_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.personal.id
  project_id = zitadel_project.nextcloud.id
  role_keys  = []
}

resource "zitadel_user_grant" "nextcloud_partner_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.partner.id
  project_id = zitadel_project.nextcloud.id
  role_keys  = []
}
