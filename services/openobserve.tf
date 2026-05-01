# Self-hosted log + metrics aggregator. Single-node mode (ZO_LOCAL_MODE=true)
# with a local-path PVC. UI on 5080, gRPC ingest on 5081.
#
# Bootstrap and provisioner are separate one-shot Jobs in
# openobserve-bootstrap.tf and openobserve-provisioner.tf. They have their
# own SPCs because they target different Vault paths
# (openobserve/service-accounts/*).

resource "kubernetes_service_account" "openobserve" {
  metadata {
    name      = "openobserve"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  automount_service_account_token = false
}

resource "random_password" "openobserve_root" {
  length  = 32
  special = false
}

locals {
  openobserve_root_email    = "admin@${local.magic_fqdn_suffix}"
  openobserve_root_password = random_password.openobserve_root.result
  openobserve_basic_b64     = base64encode("${local.openobserve_root_email}:${local.openobserve_root_password}")
  openobserve_fqdn          = "${var.openobserve_domain}.${local.magic_fqdn_suffix}"
}

module "openobserve_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "openobserve"
  namespace            = kubernetes_namespace.monitoring.metadata[0].name
  service_account_name = kubernetes_service_account.openobserve.metadata[0].name
  # Headscale user is `log`, not `openobserve` — historical naming.
  tailnet_user_id = data.terraform_remote_state.homelab.outputs.tailnet_user_map.log_server_user
}

module "openobserve_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "openobserve"
  namespace            = kubernetes_namespace.monitoring.metadata[0].name
  service_account_name = kubernetes_service_account.openobserve.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = local.openobserve_fqdn
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  # Module produces k8s secret `openobserve-secrets` with keys matching
  # objectNames (root_email, root_password, basic_b64). Pod spec below
  # uses explicit env { value_from } to remap k8s keys to the env names
  # OpenObserve actually reads (ZO_ROOT_USER_EMAIL, ZO_ROOT_USER_PASSWORD).
  # basic_b64 stays in the secret because the bootstrap job's SPC reads
  # it via separate path; provisioner reads its own service-account
  # basic_b64 from /service-accounts/provisioner.
  config_secrets = {
    root_email    = local.openobserve_root_email
    root_password = local.openobserve_root_password
    basic_b64     = local.openobserve_basic_b64
  }

  providers = { acme = acme }
}

resource "kubernetes_persistent_volume_claim" "openobserve_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "openobserve-data"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.openobserve_storage_size
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_config_map" "openobserve_env" {
  metadata {
    name      = "openobserve-env"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    ZO_LOCAL_MODE                  = "true"
    ZO_LOCAL_MODE_STORAGE          = "disk"
    ZO_DATA_DIR                    = "/data"
    ZO_HTTP_PORT                   = "5080"
    ZO_GRPC_PORT                   = "5081"
    ZO_COMPACT_DATA_RETENTION_DAYS = tostring(var.openobserve_retention_days)
    ZO_TELEMETRY                   = "false"
    # Drop INFO chatter (flight->search SQL echo + access-log middleware lines
    # that pollute the `pods` stream when searching for "error"). WARN+ still
    # surfaces ingest rejections, schema conflicts, etc.
    RUST_LOG = "warn"
  }
}

resource "kubernetes_config_map" "openobserve_nginx" {
  metadata {
    name      = "openobserve-nginx"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/openobserve.nginx.conf.tpl", {
      server_domain = local.openobserve_fqdn
    })
  }
}

resource "kubernetes_deployment" "openobserve" {
  metadata {
    name      = "openobserve"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = { app = "openobserve" }
    }

    template {
      metadata {
        labels = { app = "openobserve" }
        annotations = {
          # ConfigMaps are in the same state; hash-annotate for rolling reload.
          "openobserve-env-hash"   = sha1(jsonencode(kubernetes_config_map.openobserve_env.data))
          "openobserve-nginx-hash" = sha1(kubernetes_config_map.openobserve_nginx.data["nginx.conf"])
          # Stakater Reloader still handles Vault CSI secret rotations.
          "secret.reloader.stakater.com/reload" = "${module.openobserve_tls_vault.config_secret_name},${module.openobserve_tls_vault.tls_secret_name}"
          # Logs are high-churn ingest with built-in retention; restoring a
          # stale log corpus is rarely useful. Skip FSB on the data volume —
          # OpenObserve starts on an empty store and ingests fresh data.
          "backup.velero.io/backup-volumes-excludes" = "openobserve-data"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.openobserve.metadata[0].name

        # Wait for Vault CSI to materialize root_email/password/basic_b64
        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "root_email"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # OpenObserve container runs as UID 10001
        init_container {
          name  = "fix-permissions"
          image = var.image_busybox
          command = [
            "sh", "-c",
            "chown -R 10001:10001 /data"
          ]
          volume_mount {
            name       = "openobserve-data"
            mount_path = "/data"
          }
        }

        container {
          name  = "openobserve"
          image = var.image_openobserve

          port {
            container_port = 5080
            name           = "http"
          }
          port {
            container_port = 5081
            name           = "grpc"
          }

          # Runtime env (retention, mode, ports, etc.)
          env_from {
            config_map_ref {
              name = kubernetes_config_map.openobserve_env.metadata[0].name
            }
          }

          # Module produces k8s secret keys matching objectNames; remap
          # to the env-var names OpenObserve reads. basic_b64 lives in
          # the secret but isn't injected — it's pulled by separate SPCs
          # (otel-collector, provisioner) from different Vault paths.
          env {
            name = "ZO_ROOT_USER_EMAIL"
            value_from {
              secret_key_ref {
                name = module.openobserve_tls_vault.config_secret_name
                key  = "root_email"
              }
            }
          }
          env {
            name = "ZO_ROOT_USER_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.openobserve_tls_vault.config_secret_name
                key  = "root_password"
              }
            }
          }

          volume_mount {
            name       = "openobserve-data"
            mount_path = "/data"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "500m", memory = "512Mi" }
            limits   = { cpu = "2000m", memory = "2Gi" }
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 5080
            }
            initial_delay_seconds = 60
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 5080
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        volume {
          name = "openobserve-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.openobserve_data.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.openobserve_tls_vault.spc_name
            }
          }
        }

        # Nginx sidecar — TLS termination on 443 -> localhost:5080
        container {
          name  = "nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "openobserve-tls"
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

        volume {
          name = "openobserve-tls"
          secret { secret_name = module.openobserve_tls_vault.tls_secret_name }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.openobserve_nginx.metadata[0].name
          }
        }

        # Tailscale sidecar — advertises FQDN to the tailnet
        container {
          name  = "tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.openobserve_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.openobserve_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.openobserve_domain
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
    module.openobserve_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "openobserve" {
  metadata {
    name      = "openobserve"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    selector = { app = "openobserve" }

    port {
      name        = "http"
      port        = 5080
      target_port = 5080
    }

    port {
      name        = "grpc"
      port        = 5081
      target_port = 5081
    }
  }
}
