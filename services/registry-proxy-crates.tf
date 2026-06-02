# crates.io caching proxy with a 7-day cooldown — user-controlled fork
# (3lpsy/chilled-crates). Runs the upstream-published image
# ghcr.io/3lpsy/chilled-crates:latest (var.image_crates_proxy); the node pulls
# it through the in-cluster ghcr.io mirror like every other ghcr image. No
# in-cluster build.
#
# Lives in the shared `registry-proxy` namespace alongside the docker.io /
# ghcr.io mirrors and the npm (Verdaccio) cache. Reuses that namespace's
# ServiceAccount, RBAC Role (lists crates-tailscale-state), Vault policy +
# auth role, and netpols — all in registry-proxy.tf. Pod shape mirrors
# registry-dockerio.tf: app + nginx TLS sidecar + tailscale ingress sidecar.
#
# Supply-chain gate: CRATES_IO_PROXY_COOLDOWN=7d (var.crates_proxy_cooldown_*)
# tells the fork to drop crate versions whose sparse-index pubtime is newer
# than 7 days, so a freshly-published (possibly compromised) release can't be
# resolved until it has survived a week.

module "crates_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "crates"
  namespace            = kubernetes_namespace.registry_proxy.metadata[0].name
  service_account_name = kubernetes_service_account.registry_proxy.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.registry_proxy_server_user

  # Role/RoleBinding live in registry-proxy.tf (the shared Role lists
  # crates-tailscale-state); this module only creates the state + auth Secrets.
  manage_role = false
}

module "crates_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "crates"
  namespace            = kubernetes_namespace.registry_proxy.metadata[0].name
  service_account_name = kubernetes_service_account.registry_proxy.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = "${var.crates_domain}.${local.magic_fqdn_suffix}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  # Shared registry-proxy Vault policy + auth role live in registry-proxy.tf.
  manage_vault_auth = false
  role_name         = vault_kubernetes_auth_backend_role.registry_proxy.role_name

  providers = { acme = acme }
}

resource "kubernetes_config_map" "crates_nginx_config" {
  metadata {
    name      = "crates-nginx-config"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/registry-proxy-passthrough.nginx.conf.tpl", {
      server_domain       = "${var.crates_domain}.${local.magic_fqdn_suffix}"
      upstream_port       = "3080"
      nginx_logging_block = local.nginx_logging_blocks["crates"]
    })
  }
}

# Cache PVC — cached sparse-index entries + immutable .crate files. Own PVC
# (crates runs as uid 777, distinct fsGroup from the other pods). No
# prevent_destroy: regen-able by re-fetching from crates.io.
resource "kubernetes_persistent_volume_claim" "crates_data" {
  metadata {
    name      = "crates-data"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
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

resource "kubernetes_deployment" "crates" {
  metadata {
    name      = "crates"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "crates" }
    }

    template {
      metadata {
        labels = { app = "crates" }
        annotations = {
          "nginx-config-hash"                   = sha1(kubernetes_config_map.crates_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = module.crates_tls_vault.tls_secret_name
          # Regen-able cache — exclude from backup.
          "backup.velero.io/backup-volumes-excludes" = "crates-data"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.registry_proxy.metadata[0].name

        # Image is the public ghcr.io/3lpsy/chilled-crates (pulled via the
        # node's ghcr mirror) — no in-cluster-registry pull secret needed.

        # chilled-crates runs as uid 777 (`app`); make the cache PVC writable.
        security_context {
          fs_group = 777
        }

        init_container {
          name              = "wait-for-secrets"
          image             = var.image_busybox_pinned
          image_pull_policy = "IfNotPresent"
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "tls_crt"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        container {
          name              = "crates"
          image             = var.image_crates_proxy
          image_pull_policy = "IfNotPresent"

          port {
            container_port = 3080
            name           = "http"
          }

          env {
            name  = "CRATES_IO_PROXY_CACHE_DIR"
            value = "/var/cache/chilled-crates"
          }
          # Rewrites the served config.json download URLs back through the
          # public nginx-TLS host clients actually reach.
          env {
            name  = "CRATES_IO_PROXY_URL"
            value = "https://${var.crates_domain}.${local.magic_fqdn_suffix}/"
          }
          # 7-day cooldown (CRATES_IO_PROXY_COOLDOWN=7d).
          env {
            name  = var.crates_proxy_cooldown_env
            value = var.crates_proxy_cooldown_value
          }
          env {
            name  = "LOG_LEVEL"
            value = var.crates_proxy_log_level
          }
          # Metrics: JSON listing of cached crates at GET /metrics (port 3080,
          # reachable via the nginx passthrough at https://crates.<magic>/metrics).
          # Disabled by default (endpoint 404s) — enable it here.
          env {
            name  = "CRATES_IO_PROXY_ENABLE_METRICS"
            value = "1"
          }

          volume_mount {
            name       = "crates-cache"
            mount_path = "/var/cache/chilled-crates"
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "1", memory = "512Mi" }
          }

          liveness_probe {
            tcp_socket {
              port = 3080
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            tcp_socket {
              port = 3080
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        container {
          name              = "crates-nginx"
          image             = var.image_nginx_pinned
          image_pull_policy = "IfNotPresent"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "crates-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "1", memory = "256Mi" }
          }
        }

        container {
          name              = "crates-tailscale"
          image             = var.image_tailscale_pinned
          image_pull_policy = "IfNotPresent"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.crates_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.crates_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.crates_domain
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
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
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

        volume {
          name = "crates-cache"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.crates_data.metadata[0].name
          }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.crates_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "crates-tls"
          secret { secret_name = module.crates_tls_vault.tls_secret_name }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.crates_tls_vault.spc_name
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
    module.crates_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "crates" {
  metadata {
    name      = "crates"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }
  spec {
    selector = { app = "crates" }
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
  }
}
