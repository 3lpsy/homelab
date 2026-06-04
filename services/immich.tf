# =============================================================================
# Immich photo library, dedicated `immich` namespace.
# random_password resources below kept stable across the Phase 3 cleanup so
# postgres pg_authid (rsynced from the old nextcloud-ns instance) keeps working.
# =============================================================================

resource "random_password" "immich_db_password" {
  length  = 32
  special = false
}

resource "random_password" "immich_redis_password" {
  length  = 32
  special = false
}

resource "kubernetes_namespace" "immich" {
  metadata {
    name = "immich"
  }
}

module "immich_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.immich.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
  # internet + K8s API egress on (defaults). Both required: Tailscale
  # sidecar needs internet for Headscale/DERP and the K8s API for
  # TS_KUBE_SECRET state.
}

# Cross-ns egress: immich → oidc:443 (auth-code dance with Zitadel).
# Pod-scoped to app=immich per memory feedback_netpol_least_privilege.
# Mirror ingress lives in services/zitadel-network.tf as oidc-from-immich.
resource "kubernetes_network_policy" "immich_to_oidc" {
  metadata {
    name      = "immich-to-oidc"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = {
        app = "immich"
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
        port     = "443"
        protocol = "TCP"
      }
    }
  }
}

resource "kubernetes_service_account" "immich" {
  metadata {
    name      = "immich"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_secret" "immich_tailscale_state" {
  metadata {
    name      = "immich-tailscale-state"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  type = "Opaque"

  lifecycle {
    ignore_changes = [data, type]
  }
}

resource "kubernetes_role" "immich_tailscale" {
  metadata {
    name      = "tailscale"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["immich-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "immich_tailscale" {
  metadata {
    name      = "tailscale"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.immich_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.immich.metadata[0].name
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
}

resource "headscale_pre_auth_key" "immich_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.nextcloud_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "immich_tailscale_auth" {
  metadata {
    name      = "immich-tailscale-auth"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.immich_server.key
  }
}

# ─── Zitadel project + OIDC application + per-user grants ────────────────────
#
# Dedicated zitadel_project per service (memory feedback_zitadel_one_project_per_service).
# project_role_check=true with explicit user_grants — strict gating from day one
# (memory project_grafana_oidc_authz_pending: don't repeat the loose pattern).
resource "zitadel_project" "immich" {
  name   = "immich"
  org_id = data.zitadel_organizations.homelab.ids[0]

  project_role_assertion   = true
  project_role_check       = true
  has_project_check        = true
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"
}

resource "zitadel_project_role" "immich_user" {
  org_id       = data.zitadel_organizations.homelab.ids[0]
  project_id   = zitadel_project.immich.id
  role_key     = "immich_user"
  display_name = "Immich User"
}

resource "zitadel_application_oidc" "immich" {
  name       = "Immich"
  org_id     = data.zitadel_organizations.homelab.ids[0]
  project_id = zitadel_project.immich.id

  redirect_uris = [
    "https://${var.immich_domain}.${local.magic_fqdn_suffix}/auth/login",
    "https://${var.immich_domain}.${local.magic_fqdn_suffix}/user-settings",
    "app.immich:///oauth-callback",
  ]
  post_logout_redirect_uris = [
    "https://${var.immich_domain}.${local.magic_fqdn_suffix}/auth/login",
  ]

  response_types   = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types      = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"]
  app_type         = "OIDC_APP_TYPE_WEB"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_BASIC"
  dev_mode         = false
}

resource "zitadel_user_grant" "immich_personal_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.personal.id
  project_id = zitadel_project.immich.id
  role_keys  = [zitadel_project_role.immich_user.role_key]
}

resource "zitadel_user_grant" "immich_partner_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.partner.id
  project_id = zitadel_project.immich.id
  role_keys  = [zitadel_project_role.immich_user.role_key]
}

# Migration note: the existing admin user was OAuth-linked manually via Immich's
# /user-settings → Link OAuth flow after first password login. From that point
# Immich's getByOAuthId(sub) hits the admin record directly, so the OIDC `email`
# claim value is irrelevant for that account's logins. New users are
# auto-registered fresh on first OIDC login.
#
# Earlier draft of this file declared a `zitadel_action.immich_email_override`
# to rewrite the email claim to preferredLoginName for the email-link path.
# Removed: PRE_USERINFO_CREATION ctx exposes user/userGrants/org but NOT the
# requesting application, so per-app scoping isn't reliable; user-grant scoping
# would rewrite the email claim across other services for any user holding an
# immich grant. Manual link sidesteps both problems.

module "immich-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.immich_domain}.${local.magic_fqdn_suffix}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "vault_kv_secret_v2" "immich_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "immich/config"
  data_json = jsonencode({
    db_password    = random_password.immich_db_password.result
    redis_password = random_password.immich_redis_password.result
    # Full Immich JSON config rendered from data/immich/config.json.tpl. Mounted
    # as a file via the CSI volume; immich-server reads it via IMMICH_CONFIG_FILE.
    oidc_config_json = templatefile("${path.module}/../data/immich/config.json.tpl", {
      issuer_url          = "https://${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"
      client_id           = zitadel_application_oidc.immich.client_id
      client_secret       = zitadel_application_oidc.immich.client_secret
      button_text         = "Sign in with Zitadel"
      mobile_redirect_uri = "app.immich:///oauth-callback"
    })
  })
}

resource "vault_kv_secret_v2" "immich_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "immich/tls"
  data_json = jsonencode({
    fullchain_pem = module.immich-tls.fullchain_pem
    privkey_pem   = module.immich-tls.privkey_pem
  })

  # tls-rotator (services/tls-rotator.tf) owns rotation post-bootstrap.
  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "vault_policy" "immich" {
  name = "immich-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/immich/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "immich" {
  backend                          = "kubernetes"
  role_name                        = "immich"
  bound_service_account_names      = [kubernetes_service_account.immich.metadata[0].name]
  bound_service_account_namespaces = [kubernetes_namespace.immich.metadata[0].name]
  token_policies                   = [vault_policy.immich.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "immich_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-immich"
      namespace = kubernetes_namespace.immich.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "immich-secrets"
          type       = "Opaque"
          data = [
            {
              objectName = "immich_db_password"
              key        = "db_password"
            },
            {
              objectName = "immich_redis_password"
              key        = "redis_password"
            }
          ]
        },
        {
          secretName = "immich-tls"
          type       = "kubernetes.io/tls"
          data = [
            {
              objectName = "immich_tls_crt"
              key        = "tls.crt"
            },
            {
              objectName = "immich_tls_key"
              key        = "tls.key"
            }
          ]
        }
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "immich"
        objects = yamlencode([
          {
            objectName = "immich_db_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/immich/config"
            secretKey  = "db_password"
          },
          {
            objectName = "immich_redis_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/immich/config"
            secretKey  = "redis_password"
          },
          {
            objectName = "immich_tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/immich/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "immich_tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/immich/tls"
            secretKey  = "privkey_pem"
          },
          {
            objectName = "immich_oidc_config_json"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/immich/config"
            secretKey  = "oidc_config_json"
          }
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.immich,
    vault_kubernetes_auth_backend_role.immich,
    vault_kv_secret_v2.immich_config,
    vault_kv_secret_v2.immich_tls
  ]
}

resource "kubernetes_persistent_volume_claim" "immich_upload" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "immich-upload"
    namespace = kubernetes_namespace.immich.metadata[0].name
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

resource "kubernetes_persistent_volume_claim" "immich_postgres_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "immich-postgres-data"
    namespace = kubernetes_namespace.immich.metadata[0].name
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

resource "kubernetes_config_map" "immich_nginx_config" {
  metadata {
    name      = "immich-nginx-config"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/immich.nginx.conf.tpl", {
      server_domain       = "${var.immich_domain}.${local.magic_fqdn_suffix}"
      nginx_logging_block = local.nginx_logging_blocks["immich"]
    })
  }
}

resource "kubernetes_deployment" "immich_machine_learning" {
  metadata {
    name      = "immich-machine-learning"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "immich-machine-learning"
      }
    }

    template {
      metadata {
        labels = {
          app = "immich-machine-learning"
        }
      }

      spec {
        container {
          name  = "machine-learning"
          image = var.image_immich_ml
          image_pull_policy = "Always"

          port {
            container_port = 3003
          }

          volume_mount {
            name       = "model-cache"
            mount_path = "/cache"
          }

          resources {
            requests = {
              cpu    = "500m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "2000m"
              memory = "4Gi"
            }
          }

          liveness_probe {
            tcp_socket {
              port = 3003
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 10
          }

          readiness_probe {
            tcp_socket {
              port = 3003
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        volume {
          name = "model-cache"
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

resource "kubernetes_service" "immich_machine_learning" {
  metadata {
    name      = "immich-machine-learning"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  spec {
    selector = {
      app = "immich-machine-learning"
    }
    port {
      port        = 3003
      target_port = 3003
    }
  }
}

resource "kubernetes_deployment" "immich" {
  metadata {
    name      = "immich"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "immich"
      }
    }

    template {
      metadata {
        labels = {
          app = "immich"
        }
        annotations = {
          "nginx-config-hash"                   = sha1(kubernetes_config_map.immich_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "immich-secrets,immich-tls"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.immich.metadata[0].name

        # Pin oidc.<tailnet> to the in-cluster Zitadel ClusterIP. Immich verifies
        # OIDC tokens by fetching JWKS + userinfo on every login; SNI carries
        # the FQDN so the LE cert validates against the ClusterIP, no Tailscale
        # egress sidecar needed (memory feedback_no_egress_only_ts_sidecars).
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
              secret_file = "immich_oidc_config_json"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Immich Server
        container {
          name  = "immich-server"
          image = var.image_immich_server
          image_pull_policy = "Always"

          port {
            container_port = 2283
            name           = "http"
          }

          env {
            name  = "DB_HOSTNAME"
            value = "immich-postgres"
          }
          env {
            name  = "DB_PORT"
            value = "5432"
          }
          env {
            name  = "DB_USERNAME"
            value = "immich"
          }
          env {
            name = "DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = "immich-secrets"
                key  = "db_password"
              }
            }
          }
          env {
            name  = "DB_DATABASE_NAME"
            value = "immich"
          }

          env {
            name  = "REDIS_HOSTNAME"
            value = "immich-redis"
          }
          env {
            name  = "REDIS_PORT"
            value = "6379"
          }
          env {
            name = "REDIS_PASSWORD"
            value_from {
              secret_key_ref {
                name = "immich-secrets"
                key  = "redis_password"
              }
            }
          }

          env {
            name  = "IMMICH_MACHINE_LEARNING_URL"
            value = "http://immich-machine-learning:3003"
          }

          # JSON config file mounted via CSI from Vault (immich/config.oidc_config_json).
          # Carries OAuth/OIDC settings — issuer, client_id/secret, claims, button text.
          # File appears at /mnt/secrets/<objectName>; Immich reads it at startup.
          env {
            name  = "IMMICH_CONFIG_FILE"
            value = "/mnt/secrets/immich_oidc_config_json"
          }

          env {
            name  = "TZ"
            value = "America/Chicago"
          }

          volume_mount {
            name       = "immich-upload"
            mount_path = "/data"
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "500m"
              memory = "1Gi"
            }
            limits = {
              cpu    = "2000m"
              memory = "4Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/api/server/ping"
              port = 2283
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 10
          }

          readiness_probe {
            http_get {
              path = "/api/server/ping"
              port = 2283
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        # Immich Volumes
        volume {
          name = "immich-upload"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.immich_upload.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.immich_secret_provider.manifest.metadata.name
            }
          }
        }

        # Nginx
        container {
          name  = "immich-nginx"
          image = var.image_nginx
          image_pull_policy = "Always"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "immich-tls"
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
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "2Gi"
            }
          }
        }

        # Nginx Volumes
        volume {
          name = "immich-tls"
          secret {
            secret_name = "immich-tls"
          }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.immich_nginx_config.metadata[0].name
          }
        }

        # Tailscale
        container {
          name  = "immich-tailscale"
          image = var.image_tailscale
          image_pull_policy = "Always"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "immich-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.immich_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.immich_domain
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
    kubernetes_manifest.immich_secret_provider,
    kubernetes_role_binding.immich_tailscale,
    kubernetes_deployment.immich_postgres,
    kubernetes_deployment.immich_redis,
    kubernetes_deployment.immich_machine_learning
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_deployment" "immich_postgres" {
  metadata {
    name      = "immich-postgres"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "immich-postgres"
      }
    }

    template {
      metadata {
        labels = {
          app = "immich-postgres"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.immich.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "immich_db_password"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        container {
          name  = "postgres"
          image = var.image_immich_postgres
          image_pull_policy = "Always"

          env {
            name  = "POSTGRES_DB"
            value = "immich"
          }
          env {
            name  = "POSTGRES_USER"
            value = "immich"
          }
          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = "immich-secrets"
                key  = "db_password"
              }
            }
          }
          env {
            name  = "POSTGRES_INITDB_ARGS"
            value = "--data-checksums"
          }

          port {
            container_port = 5432
          }

          volume_mount {
            name       = "immich-postgres-data"
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
              memory = "512Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "2Gi"
            }
          }

          liveness_probe {
            exec {
              command = ["pg_isready", "-U", "immich", "-d", "immich"]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          readiness_probe {
            exec {
              command = ["pg_isready", "-U", "immich", "-d", "immich"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }

        volume {
          name = "immich-postgres-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.immich_postgres_data.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.immich_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.immich_secret_provider
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "immich_postgres" {
  metadata {
    name      = "immich-postgres"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  spec {
    selector = {
      app = "immich-postgres"
    }
    port {
      port        = 5432
      target_port = 5432
    }
  }
}

resource "kubernetes_deployment" "immich_redis" {
  metadata {
    name      = "immich-redis"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "immich-redis"
      }
    }

    template {
      metadata {
        labels = {
          app = "immich-redis"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.immich.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "immich_redis_password"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        container {
          name              = "valkey"
          image             = var.image_valkey
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
                name = "immich-secrets"
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
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "256Mi"
            }
          }

          liveness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 10
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
              secretProviderClass = kubernetes_manifest.immich_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.immich_secret_provider
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "immich_redis" {
  metadata {
    name      = "immich-redis"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  spec {
    selector = {
      app = "immich-redis"
    }
    port {
      port        = 6379
      target_port = 6379
    }
  }
}
