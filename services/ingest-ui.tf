# In-cluster registry pull secret for the `ingest` namespace.
# ingest-ui pulls its custom image from registry.<hs>.<magic> built by
# BuildKit Jobs in the builder namespace. Placed here as the only
# image-pulling consumer in this ns.
resource "kubernetes_secret" "ingest_registry_pull_secret" {
  metadata {
    name      = "registry-pull-secret"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${local.thunderbolt_registry}" = {
          username = "internal"
          password = random_password.registry_user_passwords["internal"].result
          auth     = base64encode("internal:${random_password.registry_user_passwords["internal"].result}")
        }
      }
    })
  }
}

resource "kubernetes_service_account" "ingest_ui" {
  metadata {
    name      = "ingest-ui"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }
  automount_service_account_token = false
}

# Per-user random_password. Add a name to var.ingest_ui_users to provision
# a new caller; rotate with `terraform apply -replace=random_password.ingest_ui_user_passwords[\"<name>\"]`.
resource "random_password" "ingest_ui_user_passwords" {
  for_each = toset(var.ingest_ui_users)
  length   = 32
  special  = false
}

# Bearer token shared between ingest-ui (validates inbound) and
# navidrome-ingest (sends Authorization: Bearer <token>). Stored at the
# same Vault path so both pods read the same value via their own
# read-scoped policies. Rotation = terraform apply -replace; Reloader
# rolls both pods.
resource "random_password" "ingest_internal_token" {
  length  = 48
  special = false
}

module "ingest_ui_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "ingest-ui"
  namespace            = kubernetes_namespace.ingest.metadata[0].name
  service_account_name = kubernetes_service_account.ingest_ui.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.ingest_server_user
}

# One Vault KV entry per user under ingest-ui/users/<name> with key `password`.
# Side data writes — module reads them via extra_secret_objects but doesn't
# manage the data.
resource "vault_kv_secret_v2" "ingest_ui_user" {
  for_each = toset(var.ingest_ui_users)

  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "ingest-ui/users/${each.key}"
  data_json = jsonencode({
    password = random_password.ingest_ui_user_passwords[each.key].result
  })
}

# Bearer token shared between ingest-ui (server) and navidrome-ingest (client).
resource "vault_kv_secret_v2" "ingest_internal" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "ingest-ui/internal"
  data_json = jsonencode({
    token = random_password.ingest_internal_token.result
  })
}

# Optional yt-dlp cookies (Netscape format). Empty when var.ytdlp_cookies
# is unset; the SPC still syncs an empty file, and server.py treats a
# zero-byte file as "no cookies, fall through to player_client tricks".
resource "vault_kv_secret_v2" "ytdlp_cookies" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "ingest-ui/ytdlp-cookies"
  data_json = jsonencode({
    cookies = var.ytdlp_cookies
  })
}

module "ingest_ui_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "ingest-ui"
  namespace            = kubernetes_namespace.ingest.metadata[0].name
  service_account_name = kubernetes_service_account.ingest_ui.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = "${var.ingest_ui_domain}.${local.magic_fqdn_suffix}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  # No config_secrets — ingest-ui has no <svc>/config write. All non-TLS
  # data lives under sibling Vault paths managed by the hand-rolled
  # vault_kv_secret_v2.* resources above; surface them via extra_secret_objects.
  extra_secret_objects = concat(
    [
      {
        secret_name = "ingest-ui-users"
        items = [
          for u in var.ingest_ui_users : {
            object_name = "password_${u}"
            k8s_key     = "password_${u}"
            vault_path  = "ingest-ui/users/${u}"
            vault_key   = "password"
          }
        ]
      },
    ],
    [
      {
        secret_name = "ingest-ui-internal"
        items = [{
          object_name = "internal_token"
          k8s_key     = "internal_token"
          vault_path  = "ingest-ui/internal"
          vault_key   = "token"
        }]
      },
      {
        secret_name = "ingest-ui-ytdlp-cookies"
        items = [{
          object_name = "ytdlp_cookies"
          k8s_key     = "ytdlp_cookies"
          vault_path  = "ingest-ui/ytdlp-cookies"
          vault_key   = "cookies"
        }]
      },
    ],
  )

  providers = { acme = acme }
}

module "ingest_ui_build" {
  source = "./../templates/buildkit-job"

  name      = "ingest-ui"
  image_ref = local.ingest_ui_image

  context_files = {
    "Dockerfile"     = file("${path.module}/../data/images/ingest-ui/Dockerfile")
    "server.py"      = file("${path.module}/../data/images/ingest-ui/server.py")
    "index.html"     = file("${path.module}/../data/images/ingest-ui/index.html")
    "test_server.py" = file("${path.module}/../data/images/ingest-ui/test_server.py")
  }

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}

resource "kubernetes_config_map" "ingest_ui_nginx_config" {
  metadata {
    name      = "ingest-ui-nginx-config"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/ingest-ui.nginx.conf.tpl", {
      server_domain       = "${var.ingest_ui_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
      nginx_logging_block = local.nginx_logging_blocks["ingest-ui"]
    })
  }
}

resource "kubernetes_config_map" "ingest_ui_htpasswd_script" {
  metadata {
    name      = "ingest-ui-htpasswd-script"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }
  data = {
    "htpasswd-multi.py" = file("${path.module}/../data/scripts/htpasswd-multi.py.tpl")
  }
}

locals {
  # Joined exit-node proxy URLs, sorted for stable ordering — same shape
  # as services/searxng-ranker.tf.
  ingest_ui_exitnode_proxies = join(" ", [
    for k in sort(keys(local.exitnode_names)) :
    "http://exitnode-${k}-proxy.exitnode.svc.cluster.local:8888"
  ])
}

resource "kubernetes_deployment" "ingest_ui" {
  metadata {
    name      = "ingest-ui"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "ingest-ui" }
    }

    template {
      metadata {
        labels = { app = "ingest-ui" }
        annotations = {
          "build-job"                           = module.ingest_ui_build.job_name
          "nginx-config-hash"                   = sha1(kubernetes_config_map.ingest_ui_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "ingest-ui-users,ingest-ui-internal,ingest-ui-ytdlp-cookies,ingest-ui-tls"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.ingest_ui.metadata[0].name

        image_pull_secrets {
          name = kubernetes_secret.ingest_registry_pull_secret.metadata[0].name
        }

        # Block startup until at least one user password has synced. Pick
        # the first user from var.ingest_ui_users — htpasswd-multi will
        # iterate the rest.
        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "password_${var.ingest_ui_users[0]}"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Generate /etc/nginx/htpasswd from every CSI-mounted password_<user>.
        init_container {
          name  = "render-htpasswd"
          image = var.image_python
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            "pip install --quiet bcrypt && python3 /scripts/htpasswd-multi.py",
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
          volume_mount {
            name       = "htpasswd-script"
            mount_path = "/scripts"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-htpasswd"
            mount_path = "/htpasswd"
          }
        }

        # Ensure dropzone subdirs exist with correct ownership.
        init_container {
          name  = "init-dropzone-dirs"
          image = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            "mkdir -p /dropzone/music /dropzone/music/failed /dropzone/tmp && chown -R 1000:1000 /dropzone",
          ]
          volume_mount {
            name       = "media-dropzone"
            mount_path = "/dropzone"
          }
        }

        # Application container.
        container {
          name              = "ingest-ui"
          image             = local.ingest_ui_image
          image_pull_policy = "Always"

          env {
            name  = "DROPZONE_PATH"
            value = "/dropzone"
          }
          env {
            name  = "EXITNODE_PROXIES"
            value = local.ingest_ui_exitnode_proxies
          }
          env {
            name = "INGEST_INTERNAL_TOKEN"
            value_from {
              secret_key_ref {
                name = "ingest-ui-internal"
                key  = "internal_token"
              }
            }
          }
          env {
            name  = "LOG_LEVEL"
            value = "info"
          }

          port {
            container_port = 8000
            name           = "http"
          }

          volume_mount {
            name       = "media-dropzone"
            mount_path = "/dropzone"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          security_context {
            run_as_user  = 1000
            run_as_group = 1000
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "2000m", memory = "2Gi" }
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8000
            }
            initial_delay_seconds = 15
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }

        # Nginx — TLS terminator + per-user basic auth.
        container {
          name  = "ingest-ui-nginx"
          image = var.image_nginx
          image_pull_policy = "Always"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "ingest-ui-tls"
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
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        # Tailscale ingress sidecar.
        container {
          name  = "ingest-ui-tailscale"
          image = var.image_tailscale
          image_pull_policy = "Always"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.ingest_ui_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.ingest_ui_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.ingest_ui_domain
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
            requests = { cpu = "20m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "256Mi" }
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

        # Volumes
        volume {
          name = "media-dropzone"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.media_dropzone.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.ingest_ui_tls_vault.spc_name
            }
          }
        }
        volume {
          name = "htpasswd-script"
          config_map {
            name         = kubernetes_config_map.ingest_ui_htpasswd_script.metadata[0].name
            default_mode = "0755"
          }
        }
        volume {
          name = "nginx-htpasswd"
          empty_dir {}
        }
        volume {
          name = "ingest-ui-tls"
          secret { secret_name = module.ingest_ui_tls_vault.tls_secret_name }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.ingest_ui_nginx_config.metadata[0].name
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
    module.ingest_ui_tls_vault,
    module.ingest_ui_build,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

# Internal-only Service so navidrome-ingest can pull dropzone files via
# the existing nginx (TLS + FQDN-valid cert via host_aliases). Reaches
# the same pod as the tailnet ingress sidecar — nginx routes by path.
resource "kubernetes_service" "ingest_ui_internal" {
  metadata {
    name      = "ingest-ui-internal"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }
  spec {
    selector = { app = "ingest-ui" }
    port {
      name        = "https"
      protocol    = "TCP"
      port        = 443
      target_port = 443
    }
    type = "ClusterIP"
  }
}
