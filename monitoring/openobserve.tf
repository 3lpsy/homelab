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
          "secret.reloader.stakater.com/reload" = "openobserve-secrets,openobserve-tls"
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

          # Root creds come from Vault via CSI (synced into k8s secret).
          # Optional so the Deployment can land before CSI finishes materializing.
          env_from {
            secret_ref {
              name     = "openobserve-secrets"
              optional = true
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
              secretProviderClass = kubernetes_manifest.openobserve_secret_provider.manifest.metadata.name
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
          secret { secret_name = "openobserve-tls" }
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
            value = "openobserve-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.openobserve_tailscale_auth.metadata[0].name
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
    kubernetes_manifest.openobserve_secret_provider,
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
