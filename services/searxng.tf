resource "kubernetes_namespace" "searxng" {
  metadata {
    name = "searxng"
  }
}

resource "kubernetes_service_account" "searxng" {
  metadata {
    name      = "searxng"
    namespace = kubernetes_namespace.searxng.metadata[0].name
  }
  # automount_service_account_token = true here (not false like most other
  # services) — the searxng-ranker daemon shares this SA and needs API
  # access to patch the searxng-config ConfigMap. SearXNG itself never
  # uses the token; presence is harmless.
  automount_service_account_token = true
}

resource "random_password" "searxng_secret_key" {
  length  = 64
  special = false
}

module "searxng_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "searxng"
  namespace            = kubernetes_namespace.searxng.metadata[0].name
  service_account_name = kubernetes_service_account.searxng.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.searxng_server_user
}

module "searxng_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "searxng"
  namespace            = kubernetes_namespace.searxng.metadata[0].name
  service_account_name = kubernetes_service_account.searxng.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = local.searxng_fqdn
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  config_secrets = {
    secret_key = random_password.searxng_secret_key.result
  }

  providers = { acme = acme }
}

locals {
  searxng_fqdn = "${var.searxng_domain}.${local.magic_fqdn_suffix}"
}

resource "kubernetes_config_map" "searxng_config" {
  metadata {
    name      = "searxng-config"
    namespace = kubernetes_namespace.searxng.metadata[0].name
  }

  # Seeded by Terraform, mutated continuously by searxng-ranker (reorders
  # outgoing.proxies and adds per-engine proxies based on live probe data).
  # Without this, every `terraform plan` would show drift as TF tried to
  # revert the ranker's writes.
  lifecycle {
    ignore_changes = [data]
  }

  data = {
    "settings.yml" = templatefile("${path.module}/../data/searxng/settings.yml.tpl", {
      searxng_fqdn  = local.searxng_fqdn
      exitnode_keys = sort(keys(local.exitnode_names))
    })
  }
}

resource "kubernetes_config_map" "searxng_nginx_config" {
  metadata {
    name      = "searxng-nginx-config"
    namespace = kubernetes_namespace.searxng.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/searxng.nginx.conf.tpl", {
      server_domain = local.searxng_fqdn
    })
  }
}

# NetworkPolicies for the `searxng` namespace.
#
# Hosts: searxng (with embedded valkey sidecar) + searxng-ranker daemon.
#
# Cross-namespace flows:
#   - searxng-ranker → kube-API (patches SearXNG ConfigMap) — baseline
#   - searxng-ranker → exitnode-*-proxy.exitnode.svc.cluster.local:8888
#     (probes exit-node proxies for latency/health)
#   - searxng → exitnode-*-proxy.exitnode.svc.cluster.local:8888 (per-engine
#     outgoing proxy chosen from the ranker-rewritten config)
module "searxng_netpol_baseline" {
  source = "../templates/netpol-baseline"

  namespace    = kubernetes_namespace.searxng.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

resource "kubernetes_network_policy" "searxng_to_exitnode" {
  metadata {
    name      = "searxng-to-exitnode"
    namespace = kubernetes_namespace.searxng.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.exitnode.metadata[0].name
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "8888"
      }
    }
  }
}

# Cross-ns ingress: thunderbolt-backend → searxng:443. Replaces the
# Tailscale-routed egress that thunderbolt-backend used to do via its
# now-removed sidecar (env SEARXNG_URL). thunderbolt-backend reaches
# searxng.<hs>.<magic> via host_aliases pointing at the searxng Service
# ClusterIP; nginx terminates TLS with the same FQDN-valid cert.
resource "kubernetes_network_policy" "searxng_from_thunderbolt" {
  metadata {
    name      = "searxng-from-thunderbolt"
    namespace = kubernetes_namespace.searxng.metadata[0].name
  }

  spec {
    pod_selector { match_labels = { app = "searxng" } }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.thunderbolt.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "thunderbolt-backend" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

# Cross-ns ingress: mcp-searxng → searxng:443. Replaces the Tailscale-routed
# egress that the mcp-searxng pod used to do via its now-removed sidecar
# (env MCP_SEARXNG_URL). The mcp namespace has no baseline NetworkPolicy so
# no source-side egress allow is needed; this rule is the gate.
resource "kubernetes_network_policy" "searxng_from_mcp_searxng" {
  metadata {
    name      = "searxng-from-mcp-searxng"
    namespace = kubernetes_namespace.searxng.metadata[0].name
  }

  spec {
    pod_selector { match_labels = { app = "searxng" } }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.mcp.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "mcp-searxng" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

resource "kubernetes_deployment" "searxng" {
  metadata {
    name      = "searxng"
    namespace = kubernetes_namespace.searxng.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "searxng"
      }
    }

    template {
      metadata {
        labels = {
          app = "searxng"
        }
        annotations = {
          "nginx-config-hash"                   = sha1(kubernetes_config_map.searxng_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "${module.searxng_tls_vault.config_secret_name},${module.searxng_tls_vault.tls_secret_name}"
          # Reloader watches searxng-config and rolls this Deployment whenever
          # the ranker daemon rewrites it.
          "configmap.reloader.stakater.com/reload" = "searxng-config"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.searxng.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
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

        # Copy settings.yml into a writable volume so the searxng entrypoint
        # can sed-substitute the `ultrasecretkey` placeholder with SEARXNG_SECRET.
        init_container {
          name  = "copy-config"
          image = var.image_busybox
          command = [
            "sh", "-c",
            "cp /config-ro/settings.yml /etc/searxng/settings.yml && chown -R 977:977 /etc/searxng && chmod 664 /etc/searxng/settings.yml"
          ]
          volume_mount {
            name       = "searxng-config-ro"
            mount_path = "/config-ro"
            read_only  = true
          }
          volume_mount {
            name       = "searxng-etc"
            mount_path = "/etc/searxng"
          }
        }

        # SearXNG
        container {
          name              = "searxng"
          image             = var.image_searxng
          image_pull_policy = "Always"

          env {
            name = "SEARXNG_SECRET"
            value_from {
              secret_key_ref {
                name = module.searxng_tls_vault.config_secret_name
                key  = "secret_key"
              }
            }
          }
          env {
            name  = "SEARXNG_BASE_URL"
            value = "https://${local.searxng_fqdn}/"
          }
          env {
            name  = "SEARXNG_BIND_ADDRESS"
            value = "0.0.0.0"
          }
          env {
            name  = "SEARXNG_PORT"
            value = "8080"
          }
          env {
            name  = "UWSGI_WORKERS"
            value = "4"
          }
          env {
            name  = "UWSGI_THREADS"
            value = "4"
          }

          port {
            container_port = 8080
            name           = "http"
          }

          volume_mount {
            name       = "searxng-etc"
            mount_path = "/etc/searxng"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }
        }

        # Valkey cache — localhost sidecar for searxng request cache
        # and limiter state. Ephemeral emptyDir; fine to lose on restart.
        container {
          name  = "valkey"
          image = var.image_valkey

          args = [
            "--save", "",
            "--appendonly", "no",
            "--maxmemory", "128mb",
            "--maxmemory-policy", "allkeys-lru",
            "--bind", "127.0.0.1",
          ]

          port {
            container_port = 6379
            name           = "valkey"
          }

          volume_mount {
            name       = "valkey-data"
            mount_path = "/data"
          }

          resources {
            requests = {
              cpu    = "20m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "192Mi"
            }
          }
        }

        # TLS-terminating nginx
        container {
          name  = "nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "searxng-tls"
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
              memory = "256Mi"
            }
          }
        }

        # Tailscale sidecar — registers as the `searxng` tailnet node.
        container {
          name  = "tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.searxng_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.searxng_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.searxng_domain
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

        volume {
          name = "searxng-config-ro"
          config_map {
            name = kubernetes_config_map.searxng_config.metadata[0].name
          }
        }
        volume {
          name = "searxng-etc"
          empty_dir {}
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.searxng_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "searxng-tls"
          secret {
            secret_name = module.searxng_tls_vault.tls_secret_name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.searxng_tls_vault.spc_name
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
        volume {
          name = "valkey-data"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [
    module.searxng_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "searxng" {
  metadata {
    name      = "searxng"
    namespace = kubernetes_namespace.searxng.metadata[0].name
  }
  spec {
    selector = {
      app = "searxng"
    }
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
  }
}
