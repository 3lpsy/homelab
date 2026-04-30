resource "kubernetes_deployment" "ingest_syncthing" {
  metadata {
    name      = "syncthing"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "syncthing" }
    }

    template {
      metadata {
        labels = { app = "syncthing" }
        annotations = {
          "nginx-config-hash"                   = sha1(kubernetes_config_map.ingest_syncthing_nginx_config.data["nginx.conf"])
          "syncthing-config-hash"               = sha1(kubernetes_config_map.ingest_syncthing_config_template.data["config.xml"])
          "render-script-hash"                  = sha1(kubernetes_config_map.ingest_syncthing_render_script.data["render-config.sh"])
          "secret.reloader.stakater.com/reload" = "syncthing-secrets,syncthing-tls"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.ingest_syncthing.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "gui_password"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Render config.xml: bcrypt the GUI password and substitute into the
        # template. Also bcrypt-write /etc/nginx/htpasswd for the GUI proxy.
        init_container {
          name  = "render-config"
          image = var.image_python
          command = [
            "sh", "-c",
            <<-EOT
              pip install --quiet bcrypt
              sh /scripts/render-config.sh
              python3 -c "
              import bcrypt, pathlib
              p = pathlib.Path('/mnt/secrets/gui_password').read_text().strip().encode()
              h = bcrypt.hashpw(p, bcrypt.gensalt(rounds=10)).decode()
              pathlib.Path('/htpasswd/htpasswd').write_text(f'admin:{h}\n')
              "
              chmod 0644 /htpasswd/htpasswd
            EOT
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
          volume_mount {
            name       = "config-template"
            mount_path = "/mnt/config-tpl"
            read_only  = true
          }
          volume_mount {
            name       = "render-script"
            mount_path = "/scripts"
            read_only  = true
          }
          volume_mount {
            name       = "syncthing-config-rendered"
            mount_path = "/var/syncthing/config"
          }
          volume_mount {
            name       = "nginx-htpasswd"
            mount_path = "/htpasswd"
          }
        }

        # Ensure dropzone subdirs exist with correct ownership before syncthing starts.
        init_container {
          name  = "init-dropzone-dirs"
          image = var.image_busybox
          command = [
            "sh", "-c",
            "mkdir -p /var/syncthing/folders/music /var/syncthing/folders/music/failed /var/syncthing/folders/tmp && chown -R 1000:1000 /var/syncthing/folders"
          ]
          volume_mount {
            name       = "media-dropzone"
            mount_path = "/var/syncthing/folders"
          }
        }

        # Syncthing
        container {
          name  = "syncthing"
          image = var.image_ingest_syncthing

          env {
            name  = "STNOUPGRADE"
            value = "true"
          }
          env {
            name  = "STHOMEDIR"
            value = "/var/syncthing/config"
          }

          port {
            container_port = 8384
            name           = "gui"
          }
          port {
            container_port = 22000
            name           = "sync"
            protocol       = "TCP"
          }

          security_context {
            run_as_user  = 1000
            run_as_group = 1000
          }

          volume_mount {
            name       = "syncthing-config-rendered"
            mount_path = "/var/syncthing/config"
          }
          volume_mount {
            name       = "media-dropzone"
            mount_path = "/var/syncthing/folders"
          }

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "1000m", memory = "1Gi" }
          }

          liveness_probe {
            tcp_socket {
              port = 8384
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            tcp_socket {
              port = 8384
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        # Nginx — TLS terminator + basic-auth gate on the GUI.
        container {
          name  = "syncthing-nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "syncthing-tls"
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

        # Tailscale ingress sidecar — exposes pod on the tailnet at
        # ingest-syncthing.<headscale-magic-domain>. TS_USERSPACE=false puts
        # the sidecar in the pod netns so 22000 (sync) and 443 (GUI) are
        # reachable on the tailnet IP without TS_SERVE_CONFIG forwarding.
        container {
          name  = "syncthing-tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "syncthing-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.ingest_syncthing_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.ingest_syncthing_domain
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

        volume {
          name = "media-dropzone"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.media_dropzone.metadata[0].name
          }
        }
        volume {
          name = "syncthing-config-rendered"
          empty_dir {}
        }
        volume {
          name = "config-template"
          config_map {
            name = kubernetes_config_map.ingest_syncthing_config_template.metadata[0].name
          }
        }
        volume {
          name = "render-script"
          config_map {
            name         = kubernetes_config_map.ingest_syncthing_render_script.metadata[0].name
            default_mode = "0755"
          }
        }
        volume {
          name = "nginx-htpasswd"
          empty_dir {}
        }
        volume {
          name = "syncthing-tls"
          secret { secret_name = "syncthing-tls" }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.ingest_syncthing_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.ingest_syncthing_secret_provider.manifest.metadata.name
            }
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
    kubernetes_manifest.ingest_syncthing_secret_provider,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}
