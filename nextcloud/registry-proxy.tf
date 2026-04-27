resource "kubernetes_deployment" "registry_proxy" {
  metadata {
    name      = "registry-proxy"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "registry-proxy" }
    }

    template {
      metadata {
        labels = { app = "registry-proxy" }
        annotations = {
          "registry-config-hash"                = sha1(kubernetes_config_map.registry_proxy_config.data["config.yml"])
          "nginx-config-hash"                   = sha1(kubernetes_config_map.registry_proxy_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "registry-proxy-tls"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.registry_proxy.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
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

        # Distribution in proxy/cache mode. Default ENTRYPOINT is
        # `registry`, default CMD is `serve /etc/docker/registry/config.yml`.
        # We mount our config there to take over.
        container {
          name  = "registry-proxy"
          image = var.image_registry

          port {
            container_port = 5000
            name           = "http"
          }

          volume_mount {
            name       = "registry-proxy-data"
            mount_path = "/var/lib/registry"
          }
          volume_mount {
            name       = "registry-config"
            mount_path = "/etc/docker/registry/config.yml"
            sub_path   = "config.yml"
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

        volume {
          name = "registry-proxy-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.registry_proxy_data.metadata[0].name
          }
        }
        volume {
          name = "registry-config"
          config_map {
            name = kubernetes_config_map.registry_proxy_config.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.registry_proxy_secret_provider.manifest.metadata.name
            }
          }
        }

        # Nginx — TLS termination + basic-auth gate.
        container {
          name  = "registry-proxy-nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "registry-proxy-tls"
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
          name = "registry-proxy-tls"
          secret { secret_name = "registry-proxy-tls" }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.registry_proxy_nginx_config.metadata[0].name
          }
        }

        # Tailscale sidecar — exposes the pod as
        # `registry-proxy.<magic_domain>` to the tailnet.
        container {
          name  = "registry-proxy-tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "registry-proxy-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.registry_proxy_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.registry_proxy_domain
          }
          env {
            name  = "TS_EXTRA_ARGS"
            value = "--login-server=https://${data.terraform_remote_state.homelab.outputs.headscale_server_fqdn}"
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
    kubernetes_manifest.registry_proxy_secret_provider
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}
