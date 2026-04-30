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

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "ingest-ui-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.ingest_ui_tailscale_auth.metadata[0].name
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
              secretProviderClass = kubernetes_manifest.ingest_ui_secret_provider.manifest.metadata.name
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
          secret { secret_name = "ingest-ui-tls" }
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
    kubernetes_manifest.ingest_ui_secret_provider,
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
