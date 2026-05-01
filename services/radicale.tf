resource "kubernetes_namespace" "radicale" {
  metadata {
    name = "radicale"
  }
}

resource "kubernetes_service_account" "radicale" {
  metadata {
    name      = "radicale"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }
  automount_service_account_token = false
}

resource "random_password" "radicale_password" {
  length  = 32
  special = false
}

module "radicale_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "radicale"
  namespace            = kubernetes_namespace.radicale.metadata[0].name
  service_account_name = kubernetes_service_account.radicale.metadata[0].name
  # Headscale user is `calendar`, not `radicale` — historical naming.
  tailnet_user_id = data.terraform_remote_state.homelab.outputs.tailnet_user_map.calendar_server_user
}

module "radicale_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "radicale"
  namespace            = kubernetes_namespace.radicale.metadata[0].name
  service_account_name = kubernetes_service_account.radicale.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = "${var.radicale_domain}.${local.magic_fqdn_suffix}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  config_secrets = {
    radicale_password = random_password.radicale_password.result
  }

  providers = { acme = acme }
}

resource "kubernetes_persistent_volume_claim" "radicale_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "radicale-data"
    namespace = kubernetes_namespace.radicale.metadata[0].name
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

resource "kubernetes_config_map" "radicale_config" {
  metadata {
    name      = "radicale-config"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }
  data = {
    "config" = <<-EOT
      [server]
      hosts = 0.0.0.0:5232
      max_connections = 5
      max_content_length = 100000000
      timeout = 30

      [auth]
      type = http_x_remote_user
      htpasswd_filename = /etc/radicale/users
      htpasswd_encryption = md5
      delay = 1

      [storage]
      filesystem_folder = /var/lib/radicale/collections

      [rights]
      type = from_file
      file = /etc/radicale/rights

      [logging]
      level = warning

      [web]
      type = none
    EOT

    "rights" = <<-EOT
      [root]
      user: .+
      collection:
      permissions: R

      [principal]
      user: .+
      collection: {user}
      permissions: RW

      [calendars]
      user: .+
      collection: {user}/[^/]+
      permissions: rw
    EOT
  }
}

resource "kubernetes_config_map" "radicale_nginx_config" {
  metadata {
    name      = "radicale-nginx-config"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/radicale.nginx.conf.tpl", {
      server_domain = "${var.radicale_domain}.${local.magic_fqdn_suffix}"
    })
  }
}

# NetworkPolicies for the `radicale` namespace.
#
# Single-pod namespace. Radicale's storage is on a PVC and DB writes go
# to the shared Postgres in the `nextcloud` namespace via Tailscale (the
# pod's own TS sidecar carries that traffic; NetPol-invisible).
module "radicale_netpol_baseline" {
  source = "../templates/netpol-baseline"

  namespace    = kubernetes_namespace.radicale.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

resource "kubernetes_deployment" "radicale" {
  metadata {
    name      = "radicale"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "radicale" }
    }

    template {
      metadata {
        labels = { app = "radicale" }
        annotations = {
          "config-hash"                         = sha1("${kubernetes_config_map.radicale_config.data["config"]}|${kubernetes_config_map.radicale_config.data["rights"]}")
          "nginx-config-hash"                   = sha1(kubernetes_config_map.radicale_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "${module.radicale_tls_vault.config_secret_name},${module.radicale_tls_vault.tls_secret_name}"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.radicale.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "radicale_password"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # APR-MD5 hashes the Vault-managed password into both
        # /etc/radicale/users (for radicale's own basic-auth) and
        # /etc/nginx-auth/htpasswd (for the nginx sidecar's basic-auth).
        # Single user "jim" is hardcoded — multi-user expansion would
        # need var.radicale_users + for_each random_password (see
        # registry's pattern via extra_secret_objects).
        init_container {
          name  = "setup-auth"
          image = var.image_python
          command = [
            "sh", "-c",
            <<-EOT
              pip install --quiet passlib[bcrypt]
              python -c "
              import os
              from passlib.hash import apr_md5_crypt
              p = os.environ['RADICALE_PASS']
              print('jim:' + apr_md5_crypt.hash(p))
              " > /etc/radicale/users
              chmod 640 /etc/radicale/users
              chown 1000:1000 /etc/radicale/users
              cp /etc/radicale/users /etc/nginx-auth/htpasswd
              chmod 644 /etc/nginx-auth/htpasswd
            EOT
          ]

          env {
            name = "RADICALE_PASS"
            value_from {
              secret_key_ref {
                name = module.radicale_tls_vault.config_secret_name
                key  = "radicale_password"
              }
            }
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
          volume_mount {
            name       = "radicale-auth"
            mount_path = "/etc/radicale"
          }
          volume_mount {
            name       = "nginx-auth"
            mount_path = "/etc/nginx-auth"
          }
        }

        init_container {
          name  = "fix-permissions"
          image = var.image_busybox
          command = [
            "sh", "-c",
            "chown -R 1000:1000 /var/lib/radicale/collections"
          ]
          volume_mount {
            name       = "radicale-data"
            mount_path = "/var/lib/radicale/collections"
          }
        }

        # Radicale
        container {
          name  = "radicale"
          image = var.image_radicale

          args = ["--config", "/etc/radicale/config"]

          port {
            container_port = 5232
            name           = "http"
          }

          volume_mount {
            name       = "radicale-data"
            mount_path = "/var/lib/radicale/collections"
          }
          volume_mount {
            name       = "radicale-config-vol"
            mount_path = "/etc/radicale/config"
            sub_path   = "config"
          }
          volume_mount {
            name       = "radicale-config-vol"
            mount_path = "/etc/radicale/rights"
            sub_path   = "rights"
          }
          volume_mount {
            name       = "radicale-auth"
            mount_path = "/etc/radicale/users"
            sub_path   = "users"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "250m", memory = "256Mi" }
          }

          liveness_probe {
            tcp_socket {
              port = 5232
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            tcp_socket {
              port = 5232
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        # Radicale Volumes
        volume {
          name = "radicale-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.radicale_data.metadata[0].name
          }
        }
        volume {
          name = "radicale-config-vol"
          config_map {
            name = kubernetes_config_map.radicale_config.metadata[0].name
          }
        }
        volume {
          name = "radicale-auth"
          empty_dir {}
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.radicale_tls_vault.spc_name
            }
          }
        }

        # Nginx
        container {
          name  = "radicale-nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "radicale-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }
          volume_mount {
            name       = "nginx-auth"
            mount_path = "/etc/nginx/htpasswd"
            sub_path   = "htpasswd"
            read_only  = true
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        # Nginx Volumes
        volume {
          name = "radicale-tls"
          secret { secret_name = module.radicale_tls_vault.tls_secret_name }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.radicale_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "nginx-auth"
          empty_dir {}
        }

        # Tailscale
        container {
          name  = "radicale-tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.radicale_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.radicale_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.radicale_domain
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
    module.radicale_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}
