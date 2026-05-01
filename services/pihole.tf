resource "kubernetes_namespace" "pihole" {
  metadata {
    name = "pihole"
  }
}

resource "kubernetes_service_account" "pihole" {
  metadata {
    name      = "pihole"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }
  automount_service_account_token = false
}

resource "random_password" "pihole_password" {
  length  = 32
  special = false
}

module "pihole_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "pihole"
  namespace            = kubernetes_namespace.pihole.metadata[0].name
  service_account_name = kubernetes_service_account.pihole.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.pihole_server_user
}

module "pihole_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "pihole"
  namespace            = kubernetes_namespace.pihole.metadata[0].name
  service_account_name = kubernetes_service_account.pihole.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = "${var.pihole_domain}.${local.magic_fqdn_suffix}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  config_secrets = {
    admin_password = random_password.pihole_password.result
  }

  providers = { acme = acme }
}

resource "kubernetes_persistent_volume_claim" "pihole_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "pihole-data"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_config_map" "pihole_nginx_config" {
  metadata {
    name      = "pihole-nginx-config"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/pihole.nginx.conf.tpl", {
      server_domain = "${var.pihole_domain}.${local.magic_fqdn_suffix}"
    })
  }
}

# Single-pod namespace. Pihole serves DNS to tailnet devices via its
# Tailscale sidecar (NetPol-invisible). Internet egress (covered by
# baseline) is required for Pihole's upstream DNS resolvers.
module "pihole_netpol_baseline" {
  source = "../templates/netpol-baseline"

  namespace    = kubernetes_namespace.pihole.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

resource "kubernetes_deployment" "pihole" {
  metadata {
    name      = "pihole"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "pihole" }
    }

    template {
      metadata {
        labels = { app = "pihole" }
        annotations = {
          "nginx-config-hash"                   = sha1(kubernetes_config_map.pihole_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "${module.pihole_tls_vault.config_secret_name},${module.pihole_tls_vault.tls_secret_name}"
          # Admin password and upstream DNS settings come from FTLCONF env
          # vars (Vault CSI on pod start). Query log + gravity blocklist DB
          # rebuild on first start. Nothing in this PVC is irreplaceable.
          "backup.velero.io/backup-volumes-excludes" = "pihole-data"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.pihole.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "admin_password"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # PiHole
        container {
          name  = "pihole"
          image = var.image_pihole

          env {
            name = "FTLCONF_webserver_api_password"
            value_from {
              secret_key_ref {
                name = module.pihole_tls_vault.config_secret_name
                key  = "admin_password"
              }
            }
          }
          env {
            name  = "FTLCONF_dns_upstreams"
            value = "9.9.9.9;149.112.112.112"
          }
          env {
            name  = "FTLCONF_dns_listeningMode"
            value = "all"
          }
          env {
            name  = "TZ"
            value = "America/Chicago"
          }

          port {
            container_port = 80
            name           = "http"
          }
          port {
            container_port = 53
            protocol       = "UDP"
            name           = "dns-udp"
          }
          port {
            container_port = 53
            protocol       = "TCP"
            name           = "dns-tcp"
          }

          volume_mount {
            name       = "pihole-data"
            mount_path = "/etc/pihole"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }

          liveness_probe {
            http_get {
              path = "/admin"
              port = 80
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/admin"
              port = 80
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        # PiHole Volumes
        volume {
          name = "pihole-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.pihole_data.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.pihole_tls_vault.spc_name
            }
          }
        }

        # Nginx
        container {
          name  = "pihole-nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "pihole-tls"
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
          name = "pihole-tls"
          secret { secret_name = module.pihole_tls_vault.tls_secret_name }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.pihole_nginx_config.metadata[0].name
          }
        }

        # Tailscale
        container {
          name  = "pihole-tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.pihole_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.pihole_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.pihole_domain
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
              add = ["NET_ADMIN", "NET_BIND_SERVICE", "NET_RAW", "SYS_NICE", "CHOWN"]
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
    module.pihole_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}
