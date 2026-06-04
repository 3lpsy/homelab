# Read-only, anonymous npm caching proxy (Verdaccio) with a 7-day cooldown.
#
# Lives in the shared `registry-proxy` namespace alongside the docker.io /
# ghcr.io mirrors. Reuses that namespace's ServiceAccount, RBAC Role (which
# lists npm-tailscale-state), Vault policy + auth role, and netpols — all in
# registry-proxy.tf. Pod shape mirrors registry-dockerio.tf: app + nginx TLS
# sidecar + tailscale ingress sidecar.
#
# Supply-chain gate: the BUILT-IN @verdaccio/package-filter (bundled since
# verdaccio 6.4.0) hides every npm version published < 7 days ago, so a
# freshly-compromised release can't be installed until it has survived a week.
# Enabled purely via filters in data/registry-proxy/verdaccio.config.yaml — so we
# run the STOCK upstream image, no custom build. Pure uplink cache of
# registry.npmjs.org — no private packages, no publishing (publish: nobody,
# max_users: -1).

locals {
  # Stock upstream Verdaccio, pulled through the in-cluster docker.io mirror
  # (containerd registries.yaml on the node). No custom image/build anymore — the
  # 7-day gate is the bundled @verdaccio/package-filter (since 6.4.0), enabled in
  # config. Tag `6` floats to the latest 6.x; image_pull_policy Always re-pulls on
  # every pod start to pick up patch releases.
  verdaccio_image = "verdaccio/verdaccio:6"
}

module "npm_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "npm"
  namespace            = kubernetes_namespace.registry_proxy.metadata[0].name
  service_account_name = kubernetes_service_account.registry_proxy.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.registry_proxy_server_user

  # Role/RoleBinding live in registry-proxy.tf (the shared Role lists
  # npm-tailscale-state); this module only creates the state + auth Secrets.
  manage_role = false
}

module "npm_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "npm"
  namespace            = kubernetes_namespace.registry_proxy.metadata[0].name
  service_account_name = kubernetes_service_account.registry_proxy.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = "${var.npm_domain}.${local.magic_fqdn_suffix}"
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

resource "kubernetes_config_map" "npm_nginx_config" {
  metadata {
    name      = "npm-nginx-config"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/registry-proxy-passthrough.nginx.conf.tpl", {
      server_domain       = "${var.npm_domain}.${local.magic_fqdn_suffix}"
      upstream_port       = "4873"
      nginx_logging_block = local.nginx_logging_blocks["npm"]
    })
  }
}

# Cache PVC — verdaccio storage (uplinked tarballs + metadata). Own PVC (not a
# subPath of registry-proxy-data) because verdaccio runs as uid 10001 / group
# root(0) and needs its own fsGroup, distinct from the registry pods. No
# prevent_destroy: every byte is regen-able by re-pulling from npmjs.
resource "kubernetes_persistent_volume_claim" "npm_data" {
  metadata {
    name      = "npm-data"
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

resource "kubernetes_deployment" "npm" {
  metadata {
    name      = "npm"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "npm" }
    }

    template {
      metadata {
        labels = { app = "npm" }
        annotations = {
          "nginx-config-hash"                   = sha1(kubernetes_config_map.npm_nginx_config.data["nginx.conf"])
          "verdaccio-config-hash"               = sha1(kubernetes_config_map.npm_verdaccio_config.data["config.yaml"])
          "secret.reloader.stakater.com/reload" = module.npm_tls_vault.tls_secret_name
          # Regen-able uplink cache — exclude from backup.
          "backup.velero.io/backup-volumes-excludes" = "npm-data"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.registry_proxy.metadata[0].name

        # In-cluster-registry pull secret, kept to match the sibling registry-proxy
        # pods. The images here (verdaccio, nginx, tailscale, busybox) are all stock
        # docker.io pulled via the in-cluster mirror, so it's not strictly required.
        image_pull_secrets {
          name = kubernetes_secret.registry_proxy_pull_secret.metadata[0].name
        }

        # Verdaccio runs as uid 10001 with primary group root (gid 0) — the
        # image chowns /verdaccio/storage to 10001:0 with `chmod g=u`. fsGroup
        # 0 makes the mounted PVC group-0-writable so the process can write the
        # cache/storage tree.
        security_context {
          fs_group = 0
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
          name              = "verdaccio"
          image             = local.verdaccio_image
          image_pull_policy = "Always"

          port {
            container_port = 4873
            name           = "http"
          }

          # Raise V8's heap ceiling to use the 3Gi limit below. The delay-filter
          # plugin parses + re-serializes whole packuments on every request;
          # opencode-ai's platform packages are 13-14 MB JSON each and bun fetches
          # ~13 concurrently, which V8 inflates into hundreds of MB of heap and
          # OOMKilled the old 1Gi container. Without this, V8's default cap could
          # heap-crash before the cgroup limit is even reached.
          env {
            name  = "NODE_OPTIONS"
            value = "--max-old-space-size=2560"
          }

          volume_mount {
            name       = "verdaccio-storage"
            mount_path = "/verdaccio/storage"
          }
          volume_mount {
            name       = "verdaccio-config"
            mount_path = "/verdaccio/conf/config.yaml"
            sub_path   = "config.yaml"
            read_only  = true
          }

          resources {
            # 1Gi OOMKilled (exit 137) under opencode-ai's concurrent giant
            # packuments + delay-filter re-serialization. 3Gi gives V8 room
            # (NODE_OPTIONS caps heap at 2560MB, leaving ~512MB for download
            # buffers + non-heap). cpu 2 speeds the single-threaded filter parse.
            requests = { cpu = "200m", memory = "512Mi" }
            limits   = { cpu = "2", memory = "3Gi" }
          }

          liveness_probe {
            tcp_socket {
              port = 4873
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            tcp_socket {
              port = 4873
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        container {
          name              = "npm-nginx"
          image             = var.image_nginx_pinned
          image_pull_policy = "IfNotPresent"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "npm-tls"
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
          name              = "npm-tailscale"
          image             = var.image_tailscale_pinned
          image_pull_policy = "IfNotPresent"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.npm_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.npm_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.npm_domain
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
          name = "verdaccio-storage"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.npm_data.metadata[0].name
          }
        }
        volume {
          name = "verdaccio-config"
          config_map {
            name = kubernetes_config_map.npm_verdaccio_config.metadata[0].name
          }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.npm_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "npm-tls"
          secret { secret_name = module.npm_tls_vault.tls_secret_name }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.npm_tls_vault.spc_name
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
    module.npm_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_config_map" "npm_verdaccio_config" {
  metadata {
    name      = "npm-verdaccio-config"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }
  data = {
    "config.yaml" = file("${path.module}/../data/registry-proxy/verdaccio.config.yaml")
  }
}

resource "kubernetes_service" "npm" {
  metadata {
    name      = "npm"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }
  spec {
    selector = { app = "npm" }
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
  }
}
