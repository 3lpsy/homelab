resource "kubernetes_namespace" "oidc" {
  metadata {
    name = "oidc"
    labels = {
      name = "oidc"
    }
  }
}

resource "kubernetes_service_account" "zitadel" {
  metadata {
    name      = "zitadel"
    namespace = kubernetes_namespace.oidc.metadata[0].name
  }
  automount_service_account_token = false
}

resource "random_password" "zitadel_admin" {
  length           = 32
  special          = true
  override_special = "!@#$%^&*-_+="
  # Zitadel default password complexity requires HasUpperCase, HasLowerCase,
  # HasNumber, HasSymbol — special=false trips HasSymbol on first-instance
  # bootstrap. Override the special set to avoid quote/backslash/shell hazards
  # in the value when surfaced via Vault CLI / JSON.
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
  min_special = 2
}

# Encrypts events + secrets in postgres. Rotation = re-encrypt every row;
# treat as immutable post-bootstrap.
resource "random_password" "zitadel_masterkey" {
  length  = 32
  special = false
}

resource "random_password" "zitadel_postgres" {
  length  = 32
  special = false
}

# Tiny PVC just for /zitadel/bootstrap/login-client.pat. The PAT is created
# by zitadel-api on first instance init (FIRSTINSTANCE_* env), consumed by
# the login sidecar. Must outlive pod restarts — FIRSTINSTANCE bootstrap only
# fires when no instance exists, so a wiped volume after first init = no
# regenerated PAT = login sidecar permanently broken.
resource "kubernetes_persistent_volume_claim" "zitadel_bootstrap" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "zitadel-bootstrap"
    namespace = kubernetes_namespace.oidc.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = "100Mi"
      }
    }
  }
  wait_until_bound = false
}

module "zitadel_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "zitadel"
  namespace            = kubernetes_namespace.oidc.metadata[0].name
  service_account_name = kubernetes_service_account.zitadel.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.oidc_server_user
}

module "zitadel_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "zitadel"
  namespace            = kubernetes_namespace.oidc.metadata[0].name
  service_account_name = kubernetes_service_account.zitadel.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = "${var.zitadel_domain}.${local.magic_fqdn_suffix}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = vault_mount.kv.path

  config_secrets = {
    admin_password    = random_password.zitadel_admin.result
    masterkey         = random_password.zitadel_masterkey.result
    postgres_password = random_password.zitadel_postgres.result
  }

  providers = { acme = acme }
}

resource "kubernetes_config_map" "zitadel_nginx_config" {
  metadata {
    name      = "zitadel-nginx-config"
    namespace = kubernetes_namespace.oidc.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/zitadel.nginx.conf.tpl", {
      server_domain = "${var.zitadel_domain}.${local.magic_fqdn_suffix}"
      nginx_logging_block = templatefile("${path.module}/../data/nginx/_logging.conf.tpl", {
        log_level          = var.nginx_log_level
        access_log_enabled = var.nginx_access_log_enabled
        log_static_assets  = var.nginx_log_static_assets
        access_log_target  = "/dev/stdout"
        error_log_target   = "/dev/stderr"
      })
    })
  }
}

resource "kubernetes_deployment" "zitadel" {
  metadata {
    name      = "zitadel"
    namespace = kubernetes_namespace.oidc.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "zitadel" }
    }

    template {
      metadata {
        labels = { app = "zitadel" }
        annotations = {
          "nginx-config-hash"                   = sha1(kubernetes_config_map.zitadel_nginx_config.data["nginx.conf"])
          "pat-sync-script-hash"                = sha1(kubernetes_config_map.pat_sync_script.data["sync.sh"])
          "secret.reloader.stakater.com/reload" = "${module.zitadel_tls_vault.config_secret_name},${module.zitadel_tls_vault.tls_secret_name}"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.zitadel.metadata[0].name

        # Without this, kubelet auto-injects ZITADEL_PORT=tcp://<svc-ip>:8080
        # (Docker-link-style) which collides with Zitadel's own ZITADEL_PORT
        # config var (uint16). Result: "Port cannot parse value as uint16".
        enable_service_links = false

        # pat-sync sidecar dials Vault's TLS listener on :8201 via the
        # tailnet FQDN. Vault's NetworkPolicy blocks oidc ns on :8200, but
        # the :8201 listener is wide open and the LE cert validates against
        # the FQDN. host_aliases pins that FQDN to the in-cluster ClusterIP
        # so the request never leaves the node. Same trick tls-rotator uses.
        host_aliases {
          ip        = data.terraform_remote_state.vault.outputs.vault_cluster_ip
          hostnames = ["vault.${var.headscale_subdomain}.${var.headscale_magic_domain}"]
        }

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "masterkey"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        container {
          name  = "zitadel"
          image = var.image_zitadel

          args = [
            "start-from-init",
            "--masterkeyFromEnv",
          ]

          env {
            name = "ZITADEL_MASTERKEY"
            value_from {
              secret_key_ref {
                name = module.zitadel_tls_vault.config_secret_name
                key  = "masterkey"
              }
            }
          }

          # ---- First-instance bootstrap (admin human user) ----------------
          # FIRSTINSTANCE_* envs override Zitadel's built-in defaults (which
          # would otherwise create zitadel-admin/Password1!). DEFAULTINSTANCE
          # variants don't apply here — that's for new instances created via
          # API later, not the day-zero bootstrap. These envs only fire on
          # first init; postgres wipe required to reapply.
          env {
            name  = "ZITADEL_FIRSTINSTANCE_INSTANCENAME"
            value = "homelab"
          }
          env {
            name  = "ZITADEL_FIRSTINSTANCE_ORG_NAME"
            value = "homelab"
          }
          env {
            name  = "ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME"
            value = "admin"
          }
          env {
            name  = "ZITADEL_FIRSTINSTANCE_ORG_HUMAN_FIRSTNAME"
            value = "Admin"
          }
          env {
            name  = "ZITADEL_FIRSTINSTANCE_ORG_HUMAN_LASTNAME"
            value = "User"
          }
          # Real deliverable email — populated from var.zitadel_admin_email_address.
          # Falls back to admin@<instance-domain> when unset, but that address
          # is undeliverable (instance domain is tailnet-only); only safe at
          # first init when password reset isn't yet a concern.
          env {
            name  = "ZITADEL_FIRSTINSTANCE_ORG_HUMAN_EMAIL_ADDRESS"
            value = var.zitadel_admin_email_address != "" ? var.zitadel_admin_email_address : "admin@${var.zitadel_domain}.${local.magic_fqdn_suffix}"
          }
          env {
            name  = "ZITADEL_FIRSTINSTANCE_ORG_HUMAN_EMAIL_VERIFIED"
            value = "true"
          }
          env {
            name = "ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.zitadel_tls_vault.config_secret_name
                key  = "admin_password"
              }
            }
          }
          env {
            name  = "ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORDCHANGEREQUIRED"
            value = "false"
          }

          # nginx sidecar terminates TLS — Zitadel itself speaks plain HTTP on
          # :8080. ZITADEL_TLS_ENABLED=false matches the official compose
          # pattern; pairs with ExternalSecure=true so emitted issuer URLs are
          # still https://. (The legacy --tlsMode disabled flag forces
          # ExternalSecure=false; don't use it.)
          env {
            name  = "ZITADEL_TLS_ENABLED"
            value = "false"
          }
          env {
            name  = "ZITADEL_PORT"
            value = "8080"
          }

          # ---- Login UI v2 (sibling sidecar) ------------------------------
          # First-instance bootstrap auto-creates an IAM_LOGIN_CLIENT machine
          # user + Personal Access Token written to the shared
          # zitadel-bootstrap volume. The login sidecar reads the same path.
          # These FIRSTINSTANCE_* envs only fire on day-zero init; changing
          # them later requires a fresh postgres.
          env {
            name  = "ZITADEL_FIRSTINSTANCE_LOGINCLIENTPATPATH"
            value = "/zitadel/bootstrap/login-client.pat"
          }
          env {
            name  = "ZITADEL_FIRSTINSTANCE_ORG_LOGINCLIENT_MACHINE_USERNAME"
            value = "login-client"
          }
          env {
            name  = "ZITADEL_FIRSTINSTANCE_ORG_LOGINCLIENT_MACHINE_NAME"
            value = "Automatically Initialized IAM_LOGIN_CLIENT"
          }
          env {
            name  = "ZITADEL_FIRSTINSTANCE_ORG_LOGINCLIENT_PAT_EXPIRATIONDATE"
            value = "2099-01-01T00:00:00Z"
          }

          # ---- IAM_OWNER service account for the zitadel TF provider ------
          # FIRSTINSTANCE.Org.Machine creates a machine user with IAM_OWNER
          # role + writes a PAT to the shared bootstrap volume. vault-conf
          # later reads the PAT, stores it in Vault, and wires the zitadel
          # TF provider against it for live policy/SMTP/IDP/app management
          # — no further postgres wipes needed once this PAT exists.
          env {
            name  = "ZITADEL_FIRSTINSTANCE_ORG_MACHINE_MACHINE_USERNAME"
            value = "tf-provider"
          }
          env {
            name  = "ZITADEL_FIRSTINSTANCE_ORG_MACHINE_MACHINE_NAME"
            value = "Terraform Provider (IAM_OWNER)"
          }
          # PAT output path is a TOP-LEVEL FirstInstance field, not nested
          # under Org.Machine.Pat (which only exposes ExpirationDate). Same
          # pattern as LOGINCLIENTPATPATH above.
          env {
            name  = "ZITADEL_FIRSTINSTANCE_PATPATH"
            value = "/zitadel/bootstrap/tf-provider.pat"
          }
          env {
            name  = "ZITADEL_FIRSTINSTANCE_ORG_MACHINE_PAT_EXPIRATIONDATE"
            value = "2099-01-01T00:00:00Z"
          }

          # Force OIDC + SAML auth requests through the login UI v2 (Next.js
          # sidecar). DEFAULTINSTANCE_FEATURES_* only applies at instance
          # creation; existing instance must be re-bootstrapped.
          env {
            name  = "ZITADEL_DEFAULTINSTANCE_FEATURES_LOGINV2_REQUIRED"
            value = "true"
          }
          env {
            name  = "ZITADEL_DEFAULTINSTANCE_FEATURES_LOGINV2_BASEURI"
            value = "https://${var.zitadel_domain}.${local.magic_fqdn_suffix}/ui/v2/login/"
          }
          env {
            name  = "ZITADEL_OIDC_DEFAULTLOGINURLV2"
            value = "https://${var.zitadel_domain}.${local.magic_fqdn_suffix}/ui/v2/login/login?authRequest="
          }
          env {
            name  = "ZITADEL_OIDC_DEFAULTLOGOUTURLV2"
            value = "https://${var.zitadel_domain}.${local.magic_fqdn_suffix}/ui/v2/login/logout?post_logout_redirect="
          }
          env {
            name  = "ZITADEL_SAML_DEFAULTLOGINURLV2"
            value = "https://${var.zitadel_domain}.${local.magic_fqdn_suffix}/ui/v2/login/login?samlRequest="
          }

          # Database — pod-network postgres in this namespace.
          env {
            name  = "ZITADEL_DATABASE_POSTGRES_HOST"
            value = "zitadel-postgres"
          }
          env {
            name  = "ZITADEL_DATABASE_POSTGRES_PORT"
            value = "5432"
          }
          env {
            name  = "ZITADEL_DATABASE_POSTGRES_DATABASE"
            value = "zitadel"
          }
          env {
            name  = "ZITADEL_DATABASE_POSTGRES_USER_USERNAME"
            value = "zitadel"
          }
          env {
            name = "ZITADEL_DATABASE_POSTGRES_USER_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.zitadel_tls_vault.config_secret_name
                key  = "postgres_password"
              }
            }
          }
          env {
            name  = "ZITADEL_DATABASE_POSTGRES_USER_SSL_MODE"
            value = "disable"
          }
          env {
            name  = "ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME"
            value = "zitadel"
          }
          env {
            name = "ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.zitadel_tls_vault.config_secret_name
                key  = "postgres_password"
              }
            }
          }
          env {
            name  = "ZITADEL_DATABASE_POSTGRES_ADMIN_SSL_MODE"
            value = "disable"
          }

          # Browser-facing URL — nginx sidecar terminates TLS, Zitadel itself
          # speaks plain HTTP on :8080. ExternalSecure=true tells Zitadel to
          # emit https issuer URLs even though it only sees the http hop.
          env {
            name  = "ZITADEL_EXTERNALDOMAIN"
            value = "${var.zitadel_domain}.${local.magic_fqdn_suffix}"
          }
          env {
            name  = "ZITADEL_EXTERNALPORT"
            value = "443"
          }
          env {
            name  = "ZITADEL_EXTERNALSECURE"
            value = "true"
          }

          port {
            container_port = 8080
            name           = "http"
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
          # Bootstrap shared with login sidecar: zitadel-api writes the PAT
          # here on first instance init; zitadel-login reads it at startup.
          volume_mount {
            name       = "zitadel-bootstrap"
            mount_path = "/zitadel/bootstrap"
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1000m", memory = "1Gi" }
          }

          readiness_probe {
            http_get {
              path = "/debug/ready"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        # Login UI v2 sidecar (Next.js). Version-locked to image_zitadel.
        # Crash-loops until zitadel-api writes login-client.pat to the shared
        # bootstrap volume on first init — converges automatically.
        container {
          name  = "login"
          image = var.image_zitadel_login

          env {
            name  = "ZITADEL_API_URL"
            value = "http://localhost:8080"
          }
          env {
            name  = "NEXT_PUBLIC_BASE_PATH"
            value = "/ui/v2/login"
          }
          env {
            name  = "ZITADEL_SERVICE_USER_TOKEN_FILE"
            value = "/zitadel/bootstrap/login-client.pat"
          }
          # Login app sees plain http via localhost, but external clients hit
          # https://oidc.<tailnet>. These headers stamp the public URL onto
          # outgoing requests so OIDC issuer + redirect URLs round-trip
          # correctly.
          env {
            name  = "CUSTOM_REQUEST_HEADERS"
            value = "Host:${var.zitadel_domain}.${local.magic_fqdn_suffix},X-Forwarded-Proto:https"
          }

          port {
            container_port = 3000
            name           = "login"
          }

          volume_mount {
            name       = "zitadel-bootstrap"
            mount_path = "/zitadel/bootstrap"
            read_only  = true
          }

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }

          readiness_probe {
            http_get {
              path = "/ui/v2/login/healthy"
              port = 3000
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        # pat-sync sidecar: ships login-client.pat + tf-provider.pat from
        # the bootstrap PVC into Vault KV. See vault-conf/zitadel-pat-sync.tf
        # for the policy + role + script configmap.
        container {
          name  = "pat-sync"
          image = var.image_vault_cli

          command = ["/bin/sh", "/scripts/sync.sh"]

          volume_mount {
            name       = "zitadel-bootstrap"
            mount_path = "/zitadel/bootstrap"
            read_only  = true
          }
          volume_mount {
            name       = "pat-sync-script"
            mount_path = "/scripts"
            read_only  = true
          }
          volume_mount {
            name       = "sa-token"
            mount_path = "/var/run/secrets/kubernetes.io/serviceaccount"
            read_only  = true
          }

          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "100m", memory = "64Mi" }
          }
        }

        # Nginx TLS sidecar
        container {
          name  = "nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "zitadel-tls"
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

        # Tailscale sidecar
        container {
          name  = "tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.zitadel_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.zitadel_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.zitadel_domain
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

        # Volumes
        volume {
          name = "zitadel-tls"
          secret {
            secret_name = module.zitadel_tls_vault.tls_secret_name
          }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.zitadel_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.zitadel_tls_vault.spc_name
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
        # Bootstrap volume — zitadel-api writes login-client.pat here on
        # first instance init, login sidecar reads it. MUST persist across
        # pod restarts: FIRSTINSTANCE_* bootstrap only fires once (instance
        # creation), so an emptyDir wipe = login sidecar permanently broken.
        volume {
          name = "zitadel-bootstrap"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.zitadel_bootstrap.metadata[0].name
          }
        }
        # pat-sync sidecar: script + projected SA token for Vault k8s auth.
        # SA token is projected (not auto-mounted on the SA itself) so only
        # the pat-sync container sees it — zitadel/login/nginx/tailscale
        # don't need cluster API access.
        volume {
          name = "pat-sync-script"
          config_map {
            name         = kubernetes_config_map.pat_sync_script.metadata[0].name
            default_mode = "0755"
          }
        }
        volume {
          name = "sa-token"
          projected {
            sources {
              service_account_token {
                path               = "token"
                expiration_seconds = 3600
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    module.zitadel_tls_vault,
    kubernetes_deployment.zitadel_postgres,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "zitadel" {
  metadata {
    name      = "zitadel"
    namespace = kubernetes_namespace.oidc.metadata[0].name
  }
  spec {
    selector = { app = "zitadel" }
    # Targets the nginx sidecar so consumers in other namespaces can hit
    # https://oidc.<tailnet> via host_aliases pinning the FQDN to this
    # ClusterIP — TLS cert is valid for that FQDN. No external traffic
    # uses this Service; the Tailscale sidecar handles externally-facing
    # tailnet ingress in-pod.
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
  }
}
