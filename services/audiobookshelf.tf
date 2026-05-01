resource "kubernetes_namespace" "audiobookshelf" {
  metadata {
    name = "audiobookshelf"
  }
}

resource "kubernetes_service_account" "audiobookshelf" {
  metadata {
    name      = "audiobookshelf"
    namespace = kubernetes_namespace.audiobookshelf.metadata[0].name
  }
  automount_service_account_token = false
}

# Per-user random_password. Add a name to var.audiobookshelf_users to provision
# another account; remove + apply to retire one. The first entry is the root
# admin and is also used for the POST /init bootstrap.
resource "random_password" "audiobookshelf_user_passwords" {
  for_each = toset(var.audiobookshelf_users)
  length   = 32
  special  = false
}

# Pin the JWT signing key so a wipe-and-restore of the config PVC keeps
# already-issued client tokens valid. ABS auto-generates one if absent.
resource "random_password" "audiobookshelf_jwt_secret" {
  length  = 64
  special = false
}

module "audiobookshelf_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "audiobookshelf"
  namespace            = kubernetes_namespace.audiobookshelf.metadata[0].name
  service_account_name = kubernetes_service_account.audiobookshelf.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.podcast_server_user
}

module "audiobookshelf_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "audiobookshelf"
  namespace            = kubernetes_namespace.audiobookshelf.metadata[0].name
  service_account_name = kubernetes_service_account.audiobookshelf.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = "${var.audiobookshelf_domain}.${local.magic_fqdn_suffix}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  config_secrets = merge(
    {
      jwt_secret_key = random_password.audiobookshelf_jwt_secret.result
    },
    {
      for u in var.audiobookshelf_users :
      "password_${u}" => random_password.audiobookshelf_user_passwords[u].result
    },
  )

  providers = { acme = acme }
}

resource "kubernetes_persistent_volume_claim" "audiobookshelf_config" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "audiobookshelf-config"
    namespace = kubernetes_namespace.audiobookshelf.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.audiobookshelf_config_size
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_persistent_volume_claim" "audiobookshelf_metadata" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "audiobookshelf-metadata"
    namespace = kubernetes_namespace.audiobookshelf.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.audiobookshelf_metadata_size
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_persistent_volume_claim" "audiobookshelf_podcasts" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "audiobookshelf-podcasts"
    namespace = kubernetes_namespace.audiobookshelf.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.audiobookshelf_podcasts_size
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_config_map" "audiobookshelf_nginx_config" {
  metadata {
    name      = "audiobookshelf-nginx-config"
    namespace = kubernetes_namespace.audiobookshelf.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/audiobookshelf.nginx.conf.tpl", {
      server_domain = "${var.audiobookshelf_domain}.${local.magic_fqdn_suffix}"
    })
  }
}

# Default-deny baseline — intra-ns traffic (job → server), DNS, K8s API,
# and outbound internet (tailscale sidecar + iTunes search + RSS fetches).
module "audiobookshelf_netpol_baseline" {
  source = "../templates/netpol-baseline"

  namespace    = kubernetes_namespace.audiobookshelf.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

resource "kubernetes_deployment" "audiobookshelf" {
  metadata {
    name      = "audiobookshelf"
    namespace = kubernetes_namespace.audiobookshelf.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "audiobookshelf" }
    }

    template {
      metadata {
        labels = { app = "audiobookshelf" }
        annotations = {
          "nginx-config-hash"                   = sha1(kubernetes_config_map.audiobookshelf_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "${module.audiobookshelf_tls_vault.config_secret_name},${module.audiobookshelf_tls_vault.tls_secret_name}"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.audiobookshelf.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "password_${var.audiobookshelf_users[0]}"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # ABS image runs as uid 1000 by default; ensure all three PVCs are
        # writable to that uid on first apply (idempotent on subsequent rolls).
        init_container {
          name  = "fix-permissions"
          image = var.image_busybox
          command = [
            "sh", "-c",
            "chown -R 1000:1000 /config /metadata /podcasts"
          ]
          volume_mount {
            name       = "audiobookshelf-config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "audiobookshelf-metadata"
            mount_path = "/metadata"
          }
          volume_mount {
            name       = "audiobookshelf-podcasts"
            mount_path = "/podcasts"
          }
        }

        # Audiobookshelf
        container {
          name  = "audiobookshelf"
          image = var.image_audiobookshelf

          port {
            container_port = 80
            name           = "http"
          }

          env {
            name  = "PORT"
            value = "80"
          }
          env {
            name  = "CONFIG_PATH"
            value = "/config"
          }
          env {
            name  = "METADATA_PATH"
            value = "/metadata"
          }
          env {
            name  = "TZ"
            value = "America/Chicago"
          }
          # Default V8 max heap is ~512MB on Node 20, regardless of cgroup
          # limit. Big OPML imports + 130 RSS parses concurrently push past
          # that and OOM the process. Pin heap to 1.5GB; pair with the 2Gi
          # cgroup limit below so Node has headroom.
          env {
            name  = "NODE_OPTIONS"
            value = "--max-old-space-size=1536"
          }
          # Pin the JWT signing key so DB restores keep tokens valid.
          env {
            name = "JWT_SECRET_KEY"
            value_from {
              secret_key_ref {
                name = module.audiobookshelf_tls_vault.config_secret_name
                key  = "jwt_secret_key"
              }
            }
          }

          volume_mount {
            name       = "audiobookshelf-config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "audiobookshelf-metadata"
            mount_path = "/metadata"
          }
          volume_mount {
            name       = "audiobookshelf-podcasts"
            mount_path = "/podcasts"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "100m", memory = "512Mi" }
            limits   = { cpu = "1000m", memory = "2Gi" }
          }

          liveness_probe {
            http_get {
              path = "/healthcheck"
              port = 80
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/healthcheck"
              port = 80
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        # Audiobookshelf Volumes
        volume {
          name = "audiobookshelf-config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.audiobookshelf_config.metadata[0].name
          }
        }
        volume {
          name = "audiobookshelf-metadata"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.audiobookshelf_metadata.metadata[0].name
          }
        }
        volume {
          name = "audiobookshelf-podcasts"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.audiobookshelf_podcasts.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.audiobookshelf_tls_vault.spc_name
            }
          }
        }

        # Nginx
        container {
          name  = "audiobookshelf-nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "audiobookshelf-tls"
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
          name = "audiobookshelf-tls"
          secret { secret_name = module.audiobookshelf_tls_vault.tls_secret_name }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.audiobookshelf_nginx_config.metadata[0].name
          }
        }

        # Tailscale
        container {
          name  = "audiobookshelf-tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.audiobookshelf_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.audiobookshelf_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.audiobookshelf_domain
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
    module.audiobookshelf_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

# In-cluster Service so the seed Job can reach ABS without going through
# the tailscale sidecar.
resource "kubernetes_service" "audiobookshelf" {
  metadata {
    name      = "audiobookshelf"
    namespace = kubernetes_namespace.audiobookshelf.metadata[0].name
  }

  spec {
    selector = { app = "audiobookshelf" }
    type     = "ClusterIP"

    port {
      name        = "http"
      port        = 80
      target_port = 80
      protocol    = "TCP"
    }
  }
}
