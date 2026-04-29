resource "kubernetes_deployment" "jellyfin" {
  metadata {
    name      = "jellyfin"
    namespace = kubernetes_namespace.jellyfin.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      # Single PVC RWO + a host_path GPU mount = no overlap allowed.
      type = "Recreate"
    }
    selector {
      match_labels = { app = "jellyfin" }
    }

    template {
      metadata {
        labels = { app = "jellyfin" }
        annotations = {
          "nginx-config-hash"                   = sha1(kubernetes_config_map.jellyfin_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "jellyfin-tls"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.jellyfin.metadata[0].name

        # Pod-level supplementalGroups apply to every container in the pod.
        # The Jellyfin container is the only one that touches /dev/dri, but
        # adding render+video at pod level is the only place the K8s API
        # accepts these (containerd ignores container-scoped supp groups).
        # Values match the host's `getent group render video` (Fedora 41
        # defaults: render=105, video=39). Override via tfvars if the host
        # ever renumbers.
        security_context {
          supplemental_groups = [var.jellyfin_render_gid, var.jellyfin_video_gid]
        }

        # Jellyfin's official image runs as uid 1000:1000. PVCs land
        # root-owned on first bind; chown them so the main container can
        # write. Idempotent on subsequent rolls.
        init_container {
          name  = "fix-permissions"
          image = var.image_busybox
          command = [
            "sh", "-c",
            "chown -R 1000:1000 /config /cache"
          ]
          volume_mount {
            name       = "jellyfin-config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "jellyfin-cache"
            mount_path = "/cache"
          }
        }

        # Jellyfin
        container {
          name  = "jellyfin"
          image = var.image_jellyfin

          port {
            container_port = 8096
            name           = "http"
          }

          # Pin the API listener so the nginx upstream is stable.
          env {
            name  = "JELLYFIN_PublishedServerUrl"
            value = "https://${var.jellyfin_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }

          volume_mount {
            name       = "jellyfin-config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "jellyfin-cache"
            mount_path = "/cache"
          }
          # AMD VAAPI: pass /dev/dri (renderD128 + card0) into the container.
          # Hardware accel is opt-in via the Jellyfin admin UI; this just makes
          # the device files available so the operator can flip the toggle.
          # Render + video GIDs are added at the pod-level securityContext.
          volume_mount {
            name       = "dri"
            mount_path = "/dev/dri"
          }

          resources {
            requests = { cpu = "200m", memory = "512Mi" }
            limits   = { cpu = "4000m", memory = "4Gi" }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8096
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8096
            }
            initial_delay_seconds = 20
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }

        # Jellyfin Volumes
        volume {
          name = "jellyfin-config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.jellyfin_config.metadata[0].name
          }
        }
        volume {
          name = "jellyfin-cache"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.jellyfin_cache.metadata[0].name
          }
        }
        volume {
          name = "dri"
          host_path {
            path = "/dev/dri"
          }
        }

        # Nginx — TLS terminator, reverse-proxies localhost:8096.
        container {
          name  = "jellyfin-nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "jellyfin-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }
          # Mount the CSI volume here (read-only) so the SecretProviderClass
          # reconciles and the synced jellyfin-tls k8s secret materializes
          # for nginx to read.
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets-store"
            read_only  = true
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        # Nginx Volumes
        volume {
          name = "jellyfin-tls"
          secret { secret_name = "jellyfin-tls" }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.jellyfin_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.jellyfin_secret_provider.manifest.metadata.name
            }
          }
        }

        # Tailscale — joins the tailnet as `jellyfin` under media@.
        container {
          name  = "jellyfin-tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "jellyfin-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.jellyfin_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.jellyfin_domain
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
    kubernetes_manifest.jellyfin_secret_provider
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "jellyfin" {
  metadata {
    name      = "jellyfin"
    namespace = kubernetes_namespace.jellyfin.metadata[0].name
  }

  spec {
    selector = { app = "jellyfin" }
    type     = "ClusterIP"

    port {
      name        = "https"
      port        = 443
      target_port = 443
      protocol    = "TCP"
    }
  }
}
