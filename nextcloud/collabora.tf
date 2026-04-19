resource "kubernetes_deployment" "collabora" {
  metadata {
    name      = "collabora"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "collabora"
      }
    }

    template {
      metadata {
        labels = {
          app = "collabora"
        }
        annotations = {
          "nginx-config-hash" = sha1(kubernetes_config_map.collabora_nginx_config.data["nginx.conf"])
        }
      }

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name
        # host_aliases {
        #   ip = kubernetes_service.nextcloud_internal.spec[0].cluster_ip
        #   hostnames = [
        #     "${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
        #   ]
        # }

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "collabora_password"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        init_container {
          name  = "fix-systemplate"
          image = var.image_collabora
          command = [
            "sh", "-c",
            "cp /opt/cool/systemplate/etc/* /mnt/systemplate-etc/ 2>/dev/null; cp /etc/passwd /etc/group /etc/hosts /etc/host.conf /etc/resolv.conf /mnt/systemplate-etc/ 2>/dev/null; echo 'Systemplate etc updated'"
          ]
          volume_mount {
            name       = "systemplate-etc"
            mount_path = "/mnt/systemplate-etc"
          }
        }

        # Collabora
        container {
          name  = "collabora"
          image = var.image_collabora

          env {
            name  = "aliasgroup1"
            value = "https://${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }

          env {
            name  = "server_name"
            value = "${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }

          env {
            name  = "username"
            value = "admin"
          }

          env {
            name = "password"
            value_from {
              secret_key_ref {
                name = "nextcloud-secrets"
                key  = "collabora_password"
              }
            }
          }

          env {
            name  = "extra_params"
            value = "--o:ssl.enable=false --o:ssl.termination=true --o:net.proto=https --o:storage.wopi.host=${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain} --o:logging.level=warning --o:language=en-US"
          }

          env {
            name  = "dictionaries"
            value = "en_US"
          }

          env {
            name  = "LC_CTYPE"
            value = "en_US.UTF-8"
          }

          env {
            name  = "LC_ALL"
            value = "en_US.UTF-8"
          }

          port {
            container_port = 9980
            name           = "http"
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          volume_mount {
            name       = "systemplate-etc"
            mount_path = "/opt/cool/systemplate/etc"
          }

          resources {
            requests = {
              cpu    = "1000m"
              memory = "2Gi"
            }
            limits = {
              cpu    = "4000m"
              memory = "4Gi"
            }
          }

          security_context {
            capabilities {
              add = ["SYS_CHROOT", "SYS_ADMIN", "FOWNER", "CHOWN"]
            }
          }

          liveness_probe {
            http_get {
              path = "/hosting/discovery"
              port = 9980
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 10
          }

          readiness_probe {
            http_get {
              path = "/hosting/discovery"
              port = 9980
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        # Collabora Volumes
        volume {
          name = "systemplate-etc"
          empty_dir {}
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.nextcloud_secret_provider.manifest.metadata.name
            }
          }
        }

        # Nginx
        container {
          name  = "collabora-nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "collabora-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }

          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }
        }

        # Nginx Volumes
        volume {
          name = "collabora-tls"
          secret {
            secret_name = "collabora-tls"
          }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.collabora_nginx_config.metadata[0].name
          }
        }

        # Tailscale
        container {
          name  = "collabora-tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }

          env {
            name  = "TS_KUBE_SECRET"
            value = "collabora-tailscale-state"
          }

          env {
            name  = "TS_USERSPACE"
            value = "false"
          }

          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.collabora_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }

          env {
            name  = "TS_HOSTNAME"
            value = var.collabora_domain
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
    kubernetes_manifest.nextcloud_secret_provider
  ]
}

resource "kubernetes_service" "collabora_internal" {
  metadata {
    name      = "collabora-internal"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    selector = {
      app = "collabora"
    }

    port {
      name        = "https"
      port        = 443
      target_port = 443
    }

    type = "ClusterIP"
  }
}
