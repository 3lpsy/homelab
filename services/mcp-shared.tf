resource "kubernetes_deployment" "mcp_shared" {
  metadata {
    name      = "mcp-shared"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "mcp-shared"
      }
    }

    template {
      metadata {
        labels = {
          app = "mcp-shared"
        }
        annotations = {
          "nginx-config-hash"                   = sha1(kubernetes_config_map.mcp_shared_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "mcp-auth,mcp-shared-tls"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.mcp.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "mcp_shared_tls_crt"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # TLS-terminating nginx — routes /mcp-<name>/ to the matching
        # ClusterIP service in the mcp namespace.
        container {
          name  = "nginx"
          image = var.image_nginx
          image_pull_policy = "Always"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "mcp-shared-tls"
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
              cpu    = "500m"
              memory = "256Mi"
            }
          }
        }

        # Tailscale sidecar — the only tailnet node for every MCP server now.
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
            value = "mcp-shared-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.mcp_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.mcp_shared_domain
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
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.mcp_shared_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "mcp-shared-tls"
          secret {
            secret_name = "mcp-shared-tls"
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.mcp_shared_secret_provider.manifest.metadata.name
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
    kubernetes_manifest.mcp_shared_secret_provider,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "mcp_shared" {
  metadata {
    name      = "mcp-shared"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }
  spec {
    selector = {
      app = "mcp-shared"
    }
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
  }
}

# =============================================================================
# TLS + Vault wiring (formerly mcp-shared-secrets.tf)
# =============================================================================

module "mcp-shared-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = local.mcp_shared_fqdn
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "vault_kv_secret_v2" "mcp_shared_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "mcp/mcp-shared/tls"
  data_json = jsonencode({
    fullchain_pem = module.mcp-shared-tls.fullchain_pem
    privkey_pem   = module.mcp-shared-tls.privkey_pem
  })

  # tls-rotator (services/tls-rotator.tf) owns rotation post-bootstrap.
  lifecycle {
    ignore_changes = [data_json]
  }
}

# Shared SPC — used by the mcp-shared pod (TLS for nginx) and, starting in
# Phase 2 of the consolidation, by the app pods (`mcp-auth` Secret). The
# `mcp-auth` secretObject is defined here so Phase 2 only needs to flip env
# refs on the app Deployments.
resource "kubernetes_manifest" "mcp_shared_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-mcp-shared"
      namespace = kubernetes_namespace.mcp.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "mcp-shared-tls"
          type       = "kubernetes.io/tls"
          data = [
            { objectName = "mcp_shared_tls_crt", key = "tls.crt" },
            { objectName = "mcp_shared_tls_key", key = "tls.key" },
          ]
        },
        {
          secretName = "mcp-auth"
          type       = "Opaque"
          data = [
            { objectName = "mcp_shared_api_keys_csv", key = "api_keys_csv" },
            { objectName = "mcp_shared_path_salt", key = "path_salt" },
          ]
        },
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "mcp"
        objects = yamlencode([
          { objectName = "mcp_shared_tls_crt", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/mcp/mcp-shared/tls", secretKey = "fullchain_pem" },
          { objectName = "mcp_shared_tls_key", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/mcp/mcp-shared/tls", secretKey = "privkey_pem" },
          { objectName = "mcp_shared_api_keys_csv", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/mcp/auth", secretKey = "api_keys_csv" },
          { objectName = "mcp_shared_path_salt", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/mcp/auth", secretKey = "path_salt" },
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.mcp,
    vault_kubernetes_auth_backend_role.mcp,
    vault_kv_secret_v2.mcp_shared_tls,
    vault_kv_secret_v2.mcp_auth,
  ]
}

# =============================================================================
# nginx gateway config (formerly mcp-shared-config.tf)
# =============================================================================

resource "kubernetes_config_map" "mcp_shared_nginx_config" {
  metadata {
    name      = "mcp-shared-nginx-config"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }

  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/mcp-shared.nginx.conf.tpl", {
      server_domain       = local.mcp_shared_fqdn
      services            = local.mcp_backend_services
      nginx_logging_block = local.nginx_logging_blocks["mcp-shared"]
    })
  }
}

# =============================================================================
# NetworkPolicies for the `mcp` namespace (formerly mcp-shared-network.tf)
#
# The namespace hosts mcp-shared (nginx gateway) and per-MCP backend pods
# (mcp-filesystem, mcp-memory, mcp-prometheus, mcp-k8s, mcp-litellm,
# mcp-searxng, mcp-time). External MCP traffic enters via mcp-shared's
# Tailscale sidecar (NetPol-invisible); mcp-shared then routes
# intra-namespace to backends on :8000.
#
# Per-MCP cross-namespace allows live in their own `<svc>-network.tf` files:
#   - mcp-prometheus-network.tf — egress to monitoring:9090 (Prom upstream)
#   - mcp-k8s-network.tf — kube API allow is in baseline; no cross-ns needed
#   - mcp-litellm / mcp-searxng — today reach upstreams via their own TS
#     sidecars (NetPol-invisible); after the deferred CoreDNS rewrites,
#     they'll need cross-ns allows in their respective files.
# =============================================================================

module "mcp_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.mcp.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

# Cross-ns ingress: opencode → mcp-shared:443. opencode reaches the
# shared MCP gateway via host_aliases pinning mcp-shared.<hs>.<magic> to
# the mcp-shared Service ClusterIP (per feedback_no_egress_only_ts_sidecars).
# Source-side egress allow lives in services/opencode-network.tf as
# opencode-to-mcp-shared.
resource "kubernetes_network_policy" "mcp_shared_from_opencode" {
  metadata {
    name      = "mcp-shared-from-opencode"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }

  spec {
    pod_selector { match_labels = { app = "mcp-shared" } }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.opencode.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "opencode" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}
