resource "kubernetes_deployment" "registry_dockerio" {
  metadata {
    name      = "registry-dockerio"
    namespace = kubernetes_namespace.registry_dockerio.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "registry-dockerio" }
    }

    template {
      metadata {
        labels = { app = "registry-dockerio" }
        annotations = {
          "registry-config-hash"                = sha1(kubernetes_config_map.registry_dockerio_config.data["config.yml"])
          "nginx-config-hash"                   = sha1(kubernetes_config_map.registry_dockerio_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "registry-dockerio-tls"
          # Pull-through cache of docker.io — every layer is regen-able by
          # re-pulling on cache miss. Skipping FSB saves ~tens of GB per backup.
          "backup.velero.io/backup-volumes-excludes" = "registry-dockerio-data"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.registry_dockerio.metadata[0].name

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
          name  = "registry-dockerio"
          image = var.image_registry

          # Route upstream pulls (registry-1.docker.io) through the in-cluster
          # rotating exit-node front-end. Each TCP connection picks a random
          # ProtonVPN exit, so the per-IP anonymous rate limit on Docker Hub
          # is multiplied by the number of configured exit-nodes. Distribution
          # is Go and respects HTTPS_PROXY/HTTP_PROXY for outbound; NO_PROXY
          # excludes intra-cluster traffic so this doesn't loop back through
          # the proxy chain.
          env {
            name  = "HTTPS_PROXY"
            value = "http://exitnode-haproxy.exitnode.svc.cluster.local:8888"
          }
          env {
            name  = "HTTP_PROXY"
            value = "http://exitnode-haproxy.exitnode.svc.cluster.local:8888"
          }
          env {
            name  = "NO_PROXY"
            value = "${var.k8s_pod_cidr},${var.k8s_service_cidr},127.0.0.1,localhost,.svc,.svc.cluster.local,.cluster.local"
          }

          port {
            container_port = 5000
            name           = "http"
          }

          volume_mount {
            name       = "registry-dockerio-data"
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
          name = "registry-dockerio-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.registry_dockerio_data.metadata[0].name
          }
        }
        volume {
          name = "registry-config"
          config_map {
            name = kubernetes_config_map.registry_dockerio_config.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.registry_dockerio_secret_provider.manifest.metadata.name
            }
          }
        }

        # Nginx — TLS termination + basic-auth gate.
        container {
          name  = "registry-dockerio-nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "registry-dockerio-tls"
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
          name = "registry-dockerio-tls"
          secret { secret_name = "registry-dockerio-tls" }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.registry_dockerio_nginx_config.metadata[0].name
          }
        }

        # Tailscale sidecar — exposes the pod as
        # `registry-dockerio.<magic_domain>` to the tailnet. Headscale user
        # remains "registry-proxy" (var.tailnet_users["registry_proxy_server_user"])
        # so future mirrors (registry-quayio etc.) can join the same identity
        # and ACL group while taking distinct hostnames.
        container {
          name  = "registry-dockerio-tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "registry-dockerio-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.registry_dockerio_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.registry_dockerio_domain
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
    kubernetes_manifest.registry_dockerio_secret_provider
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}
