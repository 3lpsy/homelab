resource "kubernetes_namespace" "registry" {
  metadata {
    name = "registry"
  }
}

resource "kubernetes_service_account" "registry" {
  metadata {
    name      = "registry"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }
  automount_service_account_token = false
}

# Per-user passwords. Referenced by every BuildKit-job consumer (builder,
# exitnode, ingest-ui, mcp, navidrome-ingest, nextcloud, otel-collector,
# searxng-ranker, thunderbolt, tls-rotator) for image-pull dockerconfig.
# Stays caller-owned because of those cross-file refs.
resource "random_password" "registry_user_passwords" {
  for_each = toset(var.registry_users)
  length   = 32
  special  = false
}

module "registry_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "registry"
  namespace            = kubernetes_namespace.registry.metadata[0].name
  service_account_name = kubernetes_service_account.registry.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.registry_server_user
}

# Plaintext users map at registry/config. Read by otel-collector
# (otel-collector-secrets.tf) as a Vault data source. Hand-rolled because
# the shape is `{users = {map}}` rather than the module's flat key=value.
resource "vault_kv_secret_v2" "registry_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "registry/config"
  data_json = jsonencode({
    users = {
      for user in var.registry_users :
      user => random_password.registry_user_passwords[user].result
    }
  })
}

# Bcrypt-hashed htpasswd file for the nginx sidecar's basic-auth. Bcrypt is
# non-deterministic so every plan re-hashes; ignore_changes prevents the
# fake drift. Rotation: `terraform apply -replace=vault_kv_secret_v2.registry_htpasswd`.
resource "vault_kv_secret_v2" "registry_htpasswd" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "registry/htpasswd"
  data_json = jsonencode({
    htpasswd = join("\n", [
      for user in var.registry_users :
      "${user}:${bcrypt(random_password.registry_user_passwords[user].result)}"
    ])
  })
  lifecycle {
    ignore_changes = [data_json]
  }
}

module "registry_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "registry"
  namespace            = kubernetes_namespace.registry.metadata[0].name
  service_account_name = kubernetes_service_account.registry.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = "${var.registry_domain}.${local.magic_fqdn_suffix}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  # config_secrets left empty — registry/config is hand-rolled above with a
  # users-map shape that doesn't fit the module's flat key=value. Module
  # policy still grants `registry/*` read so the SPC can fetch htpasswd
  # below.

  extra_secret_objects = [
    {
      secret_name = "registry-htpasswd"
      items = [
        {
          object_name = "htpasswd"
          k8s_key     = "htpasswd"
          vault_path  = "registry/htpasswd"
          vault_key   = "htpasswd"
        }
      ]
    }
  ]

  providers = { acme = acme }

  depends_on = [vault_kv_secret_v2.registry_htpasswd]
}

resource "kubernetes_persistent_volume_claim" "registry_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "registry-data"
    namespace = kubernetes_namespace.registry.metadata[0].name
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

resource "kubernetes_config_map" "registry_nginx_config" {
  metadata {
    name      = "registry-nginx-config"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/registry.nginx.conf.tpl", {
      server_domain = "${var.registry_domain}.${local.magic_fqdn_suffix}"
    })
  }
}

# The Registry is reached two ways:
#   - Kubelet image pulls — via the host's Tailscale interface
#     (`registry.MAGIC_DOMAIN` resolves through systemd-resolved →
#     tailscale0). Host-LOCAL source bypasses NetworkPolicy structurally,
#     so no rule needed.
#   - BuildKit Jobs in `builder` ns — push images via the cluster
#     network. Job pods use host_aliases pinning `registry.<hs>.<magic>`
#     to the registry Service ClusterIP; this allow is load-bearing.
module "registry_netpol_baseline" {
  source = "../templates/netpol-baseline"

  namespace    = kubernetes_namespace.registry.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

resource "kubernetes_network_policy" "registry_from_builder" {
  metadata {
    name      = "registry-from-builder"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "registry"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.builder.metadata[0].name
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

resource "kubernetes_deployment" "registry" {
  metadata {
    name      = "registry"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "registry" }
    }

    template {
      metadata {
        labels = { app = "registry" }
        annotations = {
          "nginx-config-hash"                   = sha1(kubernetes_config_map.registry_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "registry-htpasswd,${module.registry_tls_vault.tls_secret_name}"
          # Image layers are rebuildable from Dockerfiles in data/images/* via
          # the BuildKit jobs in the builder namespace; backing them up via
          # Velero FSB would double tens of GB for no recovery value.
          "backup.velero.io/backup-volumes-excludes" = "registry-data"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.registry.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "htpasswd"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Registry
        container {
          name  = "registry"
          image = var.image_registry

          port {
            container_port = 5000
            name           = "http"
          }

          env {
            name  = "REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY"
            value = "/var/lib/registry"
          }
          env {
            name  = "REGISTRY_HTTP_ADDR"
            value = "0.0.0.0:5000"
          }
          env {
            name  = "REGISTRY_STORAGE_DELETE_ENABLED"
            value = "true"
          }
          env {
            name  = "REGISTRY_LOG_LEVEL"
            value = "warn"
          }

          volume_mount {
            name       = "registry-data"
            mount_path = "/var/lib/registry"
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
              path = "/"
              port = 5000
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 5000
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        # Registry Volumes
        volume {
          name = "registry-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.registry_data.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.registry_tls_vault.spc_name
            }
          }
        }

        # Nginx
        container {
          name  = "registry-nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "registry-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }
          volume_mount {
            name       = "nginx-htpasswd"
            mount_path = "/etc/nginx/htpasswd"
            sub_path   = "htpasswd"
            read_only  = true
          }

          resources {
            # Bumped from 200m/128Mi: under heavy concurrent BuildKit push
            # load (cache export from many builds at once), the previous
            # limit caused `net/http: TLS handshake timeout` errors on
            # builders. TLS handshakes are CPU-bound; 1 CPU absorbs the
            # bursts, 256Mi covers parallel connection state.
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "1", memory = "256Mi" }
          }
        }

        # Nginx Volumes
        volume {
          name = "registry-tls"
          secret { secret_name = module.registry_tls_vault.tls_secret_name }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.registry_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "nginx-htpasswd"
          secret { secret_name = "registry-htpasswd" }
        }

        # Tailscale
        container {
          name  = "registry-tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.registry_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.registry_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.registry_domain
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
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
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
    module.registry_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "registry" {
  metadata {
    name      = "registry"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }
  spec {
    selector = { app = "registry" }
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
  }
}
