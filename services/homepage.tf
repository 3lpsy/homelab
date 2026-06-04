# Homepage — personal start-page listing every tailnet-fronted service.
#
# Tailnet ACL is the sole gate (no OIDC, no app-side auth). Config files
# (services / settings / bookmarks / widgets) are TF-managed: rendered
# from data/homepage/*.yaml.tpl into a ConfigMap mounted read-only at
# /app/config via subPath. To add or rearrange services, edit
# data/homepage/services.yaml.tpl and re-apply.

resource "kubernetes_namespace" "homepage" {
  metadata {
    name = "homepage"
  }
}

resource "kubernetes_service_account" "homepage" {
  metadata {
    name      = "homepage"
    namespace = kubernetes_namespace.homepage.metadata[0].name
  }
  automount_service_account_token = false
}

module "homepage_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "homepage"
  namespace            = kubernetes_namespace.homepage.metadata[0].name
  service_account_name = kubernetes_service_account.homepage.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.homepage_server_user
}

module "homepage_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "homepage"
  namespace            = kubernetes_namespace.homepage.metadata[0].name
  service_account_name = kubernetes_service_account.homepage.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = "${var.homepage_domain}.${local.magic_fqdn_suffix}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  providers = { acme = acme }
}

module "homepage_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace             = kubernetes_namespace.homepage.metadata[0].name
  pod_cidr              = var.k8s_pod_cidr
  service_cidr          = var.k8s_service_cidr
  allow_internet_egress = true
  allow_kube_api_egress = true
}

locals {
  homepage_fqdns = {
    nextcloud_fqdn        = "${var.nextcloud_domain}.${local.magic_fqdn_suffix}"
    collabora_fqdn        = "${var.collabora_domain}.${local.magic_fqdn_suffix}"
    rustical_fqdn         = "${var.rustical_domain}.${local.magic_fqdn_suffix}"
    radicale_fqdn         = "${var.radicale_domain}.${local.magic_fqdn_suffix}"
    ingest_syncthing_fqdn = "${var.ingest_syncthing_domain}.${local.magic_fqdn_suffix}"
    immich_fqdn           = "${var.immich_domain}.${local.magic_fqdn_suffix}"
    jellyfin_fqdn         = "${var.jellyfin_domain}.${local.magic_fqdn_suffix}"
    qbt_fqdn              = "${var.qbt_domain}.${local.magic_fqdn_suffix}"
    navidrome_fqdn        = "${var.navidrome_domain}.${local.magic_fqdn_suffix}"
    audiobookshelf_fqdn   = "${var.audiobookshelf_domain}.${local.magic_fqdn_suffix}"
    frigate_fqdn          = "${var.frigate_domain}.${local.magic_fqdn_suffix}"
    homeassist_fqdn       = "${var.homeassist_domain}.${local.magic_fqdn_suffix}"
    homeassist_z2m_fqdn   = "${var.homeassist_z2m_domain}.${local.magic_fqdn_suffix}"
    litellm_fqdn          = "${var.litellm_domain}.${local.magic_fqdn_suffix}"
    llm_fqdn              = "${var.llm_domain}.${local.magic_fqdn_suffix}"
    searxng_fqdn          = "${var.searxng_domain}.${local.magic_fqdn_suffix}"
    pdf_fqdn              = "${var.pdf_domain}.${local.magic_fqdn_suffix}"
    mcp_shared_fqdn       = "${var.mcp_shared_domain}.${local.magic_fqdn_suffix}"
    thunderbolt_fqdn      = "${var.thunderbolt_domain}.${local.magic_fqdn_suffix}"
    opencode_fqdn         = local.opencode_fqdn
    git_fqdn              = "${var.git_domain}.${local.magic_fqdn_suffix}"
    grafana_fqdn          = "${var.grafana_domain}.${local.magic_fqdn_suffix}"
    prometheus_fqdn       = "${var.prometheus_domain}.${local.magic_fqdn_suffix}"
    openobserve_fqdn      = "${var.openobserve_domain}.${local.magic_fqdn_suffix}"
    headlamp_fqdn         = "${var.headlamp_domain}.${local.magic_fqdn_suffix}"
    pihole_fqdn           = "${var.pihole_domain}.${local.magic_fqdn_suffix}"
    registry_fqdn         = "${var.registry_domain}.${local.magic_fqdn_suffix}"
    ntfy_fqdn             = "${var.ntfy_domain}.${local.magic_fqdn_suffix}"
    # Vault and Zitadel use literal hostname prefixes — no domain var.
    vault_fqdn = "vault.${local.magic_fqdn_suffix}"
    oidc_fqdn  = "oidc.${local.magic_fqdn_suffix}"
  }

  homepage_config_files = {
    "services.yaml"  = templatefile("${path.module}/../data/homepage/services.yaml.tpl", local.homepage_fqdns)
    "settings.yaml"  = templatefile("${path.module}/../data/homepage/settings.yaml.tpl", {})
    "bookmarks.yaml" = templatefile("${path.module}/../data/homepage/bookmarks.yaml.tpl", {})
    "widgets.yaml"   = templatefile("${path.module}/../data/homepage/widgets.yaml.tpl", {})
  }
}

resource "kubernetes_config_map" "homepage_config" {
  metadata {
    name      = "homepage-config"
    namespace = kubernetes_namespace.homepage.metadata[0].name
  }
  data = local.homepage_config_files
}

resource "kubernetes_config_map" "homepage_nginx_config" {
  metadata {
    name      = "homepage-nginx-config"
    namespace = kubernetes_namespace.homepage.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/homepage.nginx.conf.tpl", {
      server_domain       = "${var.homepage_domain}.${local.magic_fqdn_suffix}"
      nginx_logging_block = local.nginx_logging_blocks["homepage"]
    })
  }
}

resource "kubernetes_deployment" "homepage" {
  metadata {
    name      = "homepage"
    namespace = kubernetes_namespace.homepage.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "homepage" }
    }

    template {
      metadata {
        labels = { app = "homepage" }
        annotations = {
          "homepage-config-hash"                = sha1(join("\n", values(local.homepage_config_files)))
          "nginx-config-hash"                   = sha1(kubernetes_config_map.homepage_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = module.homepage_tls_vault.tls_secret_name
        }
      }

      spec {
        service_account_name = kubernetes_service_account.homepage.metadata[0].name

        # No wait-for-secrets init: nginx reads TLS from the synced k8s
        # Secret `homepage-tls`, which is mounted as a volume. Kubelet
        # blocks the pod until the SPC controller has created that
        # Secret, so the cert is already on disk when nginx starts. The
        # secrets-store CSI volume below is mounted into nginx only to
        # keep the SPC sync alive (sync requires at least one pod mount).

        # Homepage
        container {
          name              = "homepage"
          image             = var.image_homepage
          image_pull_policy = "Always"

          port {
            container_port = 3000
            name           = "http"
          }

          # Required v1.0+. Without this Homepage rejects every request
          # with 403 Bad Request when the Host header doesn't match.
          env {
            name  = "HOMEPAGE_ALLOWED_HOSTS"
            value = "${var.homepage_domain}.${local.magic_fqdn_suffix},localhost,127.0.0.1"
          }

          volume_mount {
            name       = "homepage-config"
            mount_path = "/app/config/services.yaml"
            sub_path   = "services.yaml"
            read_only  = true
          }
          volume_mount {
            name       = "homepage-config"
            mount_path = "/app/config/settings.yaml"
            sub_path   = "settings.yaml"
            read_only  = true
          }
          volume_mount {
            name       = "homepage-config"
            mount_path = "/app/config/bookmarks.yaml"
            sub_path   = "bookmarks.yaml"
            read_only  = true
          }
          volume_mount {
            name       = "homepage-config"
            mount_path = "/app/config/widgets.yaml"
            sub_path   = "widgets.yaml"
            read_only  = true
          }

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "250m", memory = "256Mi" }
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 3000
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 3000
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }
        }

        volume {
          name = "homepage-config"
          config_map {
            name = kubernetes_config_map.homepage_config.metadata[0].name
          }
        }

        # Nginx
        container {
          name              = "nginx"
          image             = var.image_nginx
          image_pull_policy = "Always"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "homepage-tls"
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

        volume {
          name = "homepage-tls"
          secret { secret_name = module.homepage_tls_vault.tls_secret_name }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.homepage_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.homepage_tls_vault.spc_name
            }
          }
        }

        # Tailscale
        container {
          name              = "tailscale"
          image             = var.image_tailscale
          image_pull_policy = "Always"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.homepage_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.homepage_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.homepage_domain
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

  depends_on = [
    module.homepage_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "homepage" {
  metadata {
    name      = "homepage"
    namespace = kubernetes_namespace.homepage.metadata[0].name
  }
  spec {
    selector = { app = "homepage" }
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
  }
}
