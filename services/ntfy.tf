# Ntfy alert relay. Lives in shared `monitoring` namespace.
#
# User passwords are TF source-of-truth: one random_password per
# var.ntfy_users entry, written to `ntfy/config` Vault path keyed as
# `password_<user>`. The seed-users init container reads them from the
# CSI mount and seeds the SQLite auth-file on every pod start.
#
# `random_password.ntfy_user_passwords` stays caller-owned because
# outputs.tf exposes specific user passwords (e.g. ntfy_grafana_password)
# and the openobserve provisioner reads the password_openobserve key
# from the same Vault path via a `data "vault_kv_secret_v2"` lookup.

resource "random_password" "ntfy_user_passwords" {
  for_each = var.ntfy_users
  length   = 32
  special  = false
}

resource "kubernetes_service_account" "ntfy" {
  metadata {
    name      = "ntfy"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  automount_service_account_token = false
}

module "ntfy_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "ntfy"
  namespace            = kubernetes_namespace.monitoring.metadata[0].name
  service_account_name = kubernetes_service_account.ntfy.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.ntfy_server_user
}

module "ntfy_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "ntfy"
  namespace            = kubernetes_namespace.monitoring.metadata[0].name
  service_account_name = kubernetes_service_account.ntfy.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = "${var.ntfy_domain}.${local.magic_fqdn_suffix}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  # Per-user passwords as <vault_kv_path>/config keys. The synced k8s
  # Secret keeps its existing name `ntfy-user-passwords` (overrides the
  # module default `ntfy-secrets`) so the Reloader annotation and any
  # external watcher don't have to change.
  config_secret_name = "ntfy-user-passwords"
  config_secrets = {
    for user, _ in var.ntfy_users :
    "password_${user}" => random_password.ntfy_user_passwords[user].result
  }

  providers = { acme = acme }
}

resource "kubernetes_persistent_volume_claim" "ntfy_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "ntfy-data"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.ntfy_storage_size
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_config_map" "ntfy_server_config" {
  metadata {
    name      = "ntfy-server-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  # auth-users / auth-access are NOT rendered here. They previously embedded
  # bcrypt hashes + the full user/role enumeration, which would land in
  # plaintext in Velero backup tarballs. Users are now seeded into the
  # SQLite auth-file (on PVC) by the seed-users init container at startup,
  # using passwords mounted via Vault CSI.
  data = {
    "server.yml" = yamlencode({
      "base-url"            = "https://${var.ntfy_domain}.${local.magic_fqdn_suffix}"
      "listen-http"         = ":8080"
      "cache-file"          = "/var/cache/ntfy/cache.db"
      "cache-duration"      = "24h"
      "auth-file"           = "/var/lib/ntfy/user.db"
      "auth-default-access" = "deny-all"
      "behind-proxy"        = true
      "upstream-base-url"   = "https://ntfy.sh"
      "enable-signup"       = false
      "enable-login"        = true
      "log-level"           = "info"
      "log-format"          = "json"
    })
  }
}

resource "kubernetes_config_map" "ntfy_seed_script" {
  metadata {
    name      = "ntfy-seed-script"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "seed-users.sh" = templatefile("${path.module}/../data/ntfy/seed-users.sh.tpl", {
      users = var.ntfy_users
    })
  }
}

resource "kubernetes_config_map" "ntfy_nginx_config" {
  metadata {
    name      = "ntfy-nginx-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/ntfy.nginx.conf.tpl", {
      server_domain = "${var.ntfy_domain}.${local.magic_fqdn_suffix}"
    })
  }
}

resource "kubernetes_deployment" "ntfy" {
  metadata {
    name      = "ntfy"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "ntfy" }
    }

    template {
      metadata {
        labels = { app = "ntfy" }
        annotations = {
          "nginx-config-hash"                   = sha1(kubernetes_config_map.ntfy_nginx_config.data["nginx.conf"])
          "seed-script-hash"                    = sha1(kubernetes_config_map.ntfy_seed_script.data["seed-users.sh"])
          "secret.reloader.stakater.com/reload" = "${module.ntfy_tls_vault.tls_secret_name},${module.ntfy_tls_vault.config_secret_name}"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.ntfy.metadata[0].name

        init_container {
          name  = "fix-permissions"
          image = var.image_busybox
          command = [
            "sh", "-c",
            "chown -R 1000:1000 /var/lib/ntfy && chown -R 1000:1000 /var/cache/ntfy"
          ]
          volume_mount {
            name       = "ntfy-data"
            mount_path = "/var/lib/ntfy"
          }
          volume_mount {
            name       = "ntfy-cache"
            mount_path = "/var/cache/ntfy"
          }
        }

        # Seed users into the SQLite auth-file from passwords mounted via
        # Vault CSI. Runs after fix-permissions, before the main ntfy
        # container starts, so the auth DB is ready when ntfy serves.
        init_container {
          name  = "seed-users"
          image = var.image_ntfy
          command = ["sh", "/scripts/seed-users.sh"]

          security_context {
            run_as_user  = 1000
            run_as_group = 1000
          }

          volume_mount {
            name       = "ntfy-config"
            mount_path = "/etc/ntfy"
            read_only  = true
          }
          volume_mount {
            name       = "ntfy-data"
            mount_path = "/var/lib/ntfy"
          }
          volume_mount {
            name       = "ntfy-cache"
            mount_path = "/var/cache/ntfy"
          }
          volume_mount {
            name       = "ntfy-seed-script"
            mount_path = "/scripts"
            read_only  = true
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        # Ntfy
        container {
          name  = "ntfy"
          image = var.image_ntfy

          args = ["serve"]

          port {
            container_port = 8080
            name           = "http"
          }

          volume_mount {
            name       = "ntfy-config"
            mount_path = "/etc/ntfy"
            read_only  = true
          }
          volume_mount {
            name       = "ntfy-data"
            mount_path = "/var/lib/ntfy"
          }
          volume_mount {
            name       = "ntfy-cache"
            mount_path = "/var/cache/ntfy"
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "250m", memory = "256Mi" }
          }

          liveness_probe {
            http_get {
              path = "/v1/health"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/v1/health"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        # Ntfy Volumes
        volume {
          name = "ntfy-config"
          config_map {
            name = kubernetes_config_map.ntfy_server_config.metadata[0].name
          }
        }
        volume {
          name = "ntfy-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.ntfy_data.metadata[0].name
          }
        }
        volume {
          name = "ntfy-cache"
          empty_dir {}
        }
        volume {
          name = "ntfy-seed-script"
          config_map {
            name         = kubernetes_config_map.ntfy_seed_script.metadata[0].name
            default_mode = "0755"
          }
        }

        # Nginx
        container {
          name  = "nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "ntfy-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        # Nginx Volumes
        volume {
          name = "ntfy-tls"
          secret { secret_name = module.ntfy_tls_vault.tls_secret_name }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.ntfy_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.ntfy_tls_vault.spc_name
            }
          }
        }

        # Tailscale
        container {
          name  = "tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.ntfy_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.ntfy_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.ntfy_domain
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
    module.ntfy_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

# nginx sidecar terminates TLS with the ntfy.<hs>.<magic> cert. In-cluster
# callers (prometheus pod's ntfy-bridge container) reach :443 here via
# host_aliases so SNI + cert validation continue to work without going
# through the ntfy pod's tailscale sidecar.
resource "kubernetes_service" "ntfy" {
  metadata {
    name      = "ntfy"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  spec {
    selector = { app = "ntfy" }
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
  }
}
