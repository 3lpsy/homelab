resource "kubernetes_deployment" "frigate" {
  metadata {
    name      = "frigate"
    namespace = kubernetes_namespace.frigate.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "frigate" }
    }

    template {
      metadata {
        labels = { app = "frigate" }
        annotations = {
          "config-hash"                         = sha1(kubernetes_config_map.frigate_config.data["config.yml"])
          "nginx-config-hash"                   = sha1(kubernetes_config_map.frigate_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "frigate-tls,frigate-secrets"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.frigate.metadata[0].name

        # Host is Fedora: video=39, render=105 (mode 0666 on renderD128 means
        # render membership isn't strictly required, but harmless). card0 is
        # 0660 root:video — VAAPI only touches renderD128 so video membership
        # is also not strictly required, kept defensively. Re-check GIDs if
        # the node is reprovisioned to a different distro.
        security_context {
          supplemental_groups = [39, 105]
          fs_group            = 1000
        }

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

        # Seeds Frigate's auth db with the Vault-managed admin password
        # before the main container starts. Script body lives at
        # data/frigate/seed-admin.py — see that file for the schema-aware
        # upsert + PBKDF2 hash details.
        init_container {
          name  = "seed-admin-user"
          image = var.image_frigate
          command = [
            "python3", "-c", file("${path.module}/../data/frigate/seed-admin.py")
          ]
          volume_mount {
            name       = "frigate-config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Frigate
        container {
          name  = "frigate"
          image = var.image_frigate

          port {
            container_port = 8971
            name           = "https-auth"
          }

          env {
            name  = "TZ"
            value = var.homeassist_time_zone
          }

          # Frigate ffmpeg uses /dev/shm for inter-process frame buffers.
          # The container default (64Mi) is too small for anything past one
          # camera; bump via a Memory-backed emptyDir.
          volume_mount {
            name       = "dshm"
            mount_path = "/dev/shm"
          }
          volume_mount {
            name       = "frigate-config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "frigate-recordings"
            mount_path = "/media/frigate"
          }
          volume_mount {
            name       = "frigate-config-file"
            mount_path = "/config/config.yml"
            sub_path   = "config.yml"
          }
          # AMD VAAPI render node passthrough for ffmpeg hwaccel decode.
          # The whole /dev/dri dir is mounted because ffmpeg probes both
          # card0 and renderD128 during VAAPI init.
          volume_mount {
            name       = "dri"
            mount_path = "/dev/dri"
          }
          # Pins the CSI secrets-store volume so the synced `frigate-tls`
          # k8s secret stays alive for the nginx sidecar; Frigate itself
          # never reads from this path.
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "500m", memory = "1Gi" }
            limits   = { cpu = "4000m", memory = "4Gi" }
          }

          liveness_probe {
            tcp_socket {
              port = 8971
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            timeout_seconds       = 10
            failure_threshold     = 5
          }

          readiness_probe {
            tcp_socket {
              port = 8971
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        # Frigate Volumes
        volume {
          name = "frigate-config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.frigate_config.metadata[0].name
          }
        }
        volume {
          name = "frigate-recordings"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.frigate_recordings.metadata[0].name
          }
        }
        volume {
          name = "frigate-config-file"
          config_map {
            name = kubernetes_config_map.frigate_config.metadata[0].name
          }
        }
        volume {
          name = "dshm"
          empty_dir {
            medium     = "Memory"
            size_limit = "512Mi"
          }
        }
        volume {
          name = "dri"
          host_path {
            path = "/dev/dri"
            type = "Directory"
          }
        }

        # Nginx
        container {
          name  = "frigate-nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "frigate-tls"
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
          name = "frigate-tls"
          secret { secret_name = "frigate-tls" }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.frigate_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.frigate_secret_provider.manifest.metadata.name
            }
          }
        }

        # Tailscale
        container {
          name  = "frigate-tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "frigate-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.frigate_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.frigate_domain
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
    kubernetes_manifest.frigate_secret_provider
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}
