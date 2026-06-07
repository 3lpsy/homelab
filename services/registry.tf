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
# exitnode, mcp, nextcloud, otel-collector, searxng-ranker, thunderbolt,
# tls-rotator) for image-pull dockerconfig.
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
# (otel-collector.tf) as a Vault data source. Hand-rolled because
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

# Plaintext per-user password source for the registry nginx htpasswd.
#
# The htpasswd file is NOT generated at TF time: bcrypt() is non-deterministic
# (re-salts every plan), which is why the old TF-built `registry/htpasswd` Vault
# secret carried `lifecycle { ignore_changes = [data_json] }` to suppress the
# churn — but that froze the WHOLE value, so a new user added to
# var.registry_users never propagated and the registry 401'd it (this bit the
# git-runner `forgejo-runner` user). {SHA}/{PLAIN} are the only schemes TF could
# emit deterministically, and both are weak.
#
# Instead, follow the repo's runtime-hash convention (ingest-syncthing,
# homeassist-mosquitto): TF ships only the plaintext (deterministic — same data
# already in registry/config), and the `build-htpasswd` init container hashes it
# to salted nginx {SSHA} at pod start. Deterministic source ⇒ no fake drift, no
# ignore_changes; adding a user is a real diff that flows: this Secret changes →
# Reloader rolls the registry → the init regenerates htpasswd with the new user.
# Stdlib-only hashing (hashlib/base64/os) — deliberately NO uv/PyPI fetch in the
# critical registry's startup path.
# Rotate a user: `terraform apply -replace='random_password.registry_user_passwords["<user>"]'`.
resource "kubernetes_secret" "registry_htpasswd_src" {
  metadata {
    name      = "registry-htpasswd-src"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }
  data = {
    for user in var.registry_users :
    "password_${user}" => random_password.registry_user_passwords[user].result
  }
}

# {SSHA} htpasswd generator run by the build-htpasswd init container.
resource "kubernetes_config_map" "registry_htpasswd_script" {
  metadata {
    name      = "registry-htpasswd-script"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }
  data = {
    "registry-htpasswd-ssha.py" = file("${path.module}/../data/scripts/registry-htpasswd-ssha.py")
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
  # users-map shape that doesn't fit the module's flat key=value. The htpasswd
  # is no longer sourced from Vault/CSI (the nginx file is built at runtime by
  # the build-htpasswd init from kubernetes_secret.registry_htpasswd_src), so
  # this module now manages only the TLS cert + SPC.

  providers = { acme = acme }
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
      server_domain       = "${var.registry_domain}.${local.magic_fqdn_suffix}"
      nginx_logging_block = local.nginx_logging_blocks["registry"]
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
          "htpasswd-script-hash"                = sha1(kubernetes_config_map.registry_htpasswd_script.data["registry-htpasswd-ssha.py"])
          "secret.reloader.stakater.com/reload" = "registry-htpasswd-src,${module.registry_tls_vault.tls_secret_name}"
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
          image = var.image_busybox_pinned
          image_pull_policy = "IfNotPresent"
          command = [
            "sh", "-c",
            # Gate on the CSI-mounted TLS cert (htpasswd no longer comes from
            # CSI — it's built by the build-htpasswd init below).
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

        # Build the nginx htpasswd from the plaintext per-user passwords using
        # salted nginx {SSHA} (stdlib hashlib/base64/os — NO uv/PyPI fetch, so
        # the critical registry's startup has no external dependency). Reads
        # /mnt/secrets/password_<user> from registry_htpasswd_src and writes
        # /htpasswd/htpasswd (emptyDir shared with the nginx sidecar). Reruns on
        # every roll, so adding/rotating a user (which rolls the pod via
        # Reloader) regenerates the file.
        init_container {
          name              = "build-htpasswd"
          image             = var.python_base_image
          image_pull_policy = "IfNotPresent"
          # Tested: data/scripts/test_registry_htpasswd_ssha.py.
          command = ["python3", "/scripts/registry-htpasswd-ssha.py"]
          env {
            name  = "HTPASSWD_SRC_DIR"
            value = "/mnt/htpasswd-src"
          }
          env {
            name  = "HTPASSWD_OUT_FILE"
            value = "/htpasswd/htpasswd"
          }
          volume_mount {
            name       = "htpasswd-script"
            mount_path = "/scripts"
            read_only  = true
          }
          volume_mount {
            name       = "htpasswd-src"
            mount_path = "/mnt/htpasswd-src"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-htpasswd"
            mount_path = "/htpasswd"
          }
        }

        # Registry
        container {
          name  = "registry"
          image = var.image_registry
          image_pull_policy = "IfNotPresent"

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
          image = var.image_nginx_pinned
          image_pull_policy = "IfNotPresent"

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
            # registry-nginx terminates TLS + proxies blob pushes. With
            # proxy_request_buffering OFF (see registry.nginx.conf.tpl) large
            # layer PUTs stream straight to the registry instead of buffering to
            # RAM — but a full mass-rebuild still pushes many big layers at once,
            # and 256Mi got OOMKilled (exit 137, crashloop → builders saw
            # `connection reset by peer` / `connection refused` on push). 1Gi +
            # 2 CPU absorbs the concurrent TLS + streaming load.
            requests = { cpu = "200m", memory = "256Mi" }
            limits   = { cpu = "2", memory = "1Gi" }
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
        # Built at runtime by the build-htpasswd init; shared with the nginx
        # sidecar (which mounts it at /etc/nginx/htpasswd via subPath).
        volume {
          name = "nginx-htpasswd"
          empty_dir {}
        }
        # Plaintext per-user passwords consumed only by build-htpasswd.
        volume {
          name = "htpasswd-src"
          secret {
            secret_name = kubernetes_secret.registry_htpasswd_src.metadata[0].name
          }
        }
        volume {
          name = "htpasswd-script"
          config_map {
            name = kubernetes_config_map.registry_htpasswd_script.metadata[0].name
          }
        }

        # Tailscale
        container {
          name  = "registry-tailscale"
          image = var.image_tailscale_pinned
          image_pull_policy = "IfNotPresent"

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
