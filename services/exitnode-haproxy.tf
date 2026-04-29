# Rotating exit-node front-end. One TCP front-end on :8888 that randomly
# selects a backing exit-node tinyproxy per connection. Clients use this in
# place of any single exit-node service to spread egress across all configured
# WireGuard tunnels — useful for dodging per-IP rate limits (Docker Hub etc.)
# without having to pin a specific region.
#
# Reach as: exitnode-haproxy.exitnode.svc.cluster.local:8888
# Health:   exitnode-haproxy.exitnode.svc.cluster.local:8889/healthz
#
# Stateless, single replica is fine — HA could bump to 2+ if the rotator
# itself becomes a single point of failure for cluster egress.

resource "kubernetes_deployment" "exitnode_haproxy" {
  metadata {
    name      = "exitnode-haproxy"
    namespace = kubernetes_namespace.exitnode.metadata[0].name
    labels = {
      app                      = "exitnode-haproxy"
      "app.kubernetes.io/name" = "exitnode-haproxy"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "exitnode-haproxy" }
    }

    template {
      metadata {
        labels = {
          app                      = "exitnode-haproxy"
          "app.kubernetes.io/name" = "exitnode-haproxy"
        }
        annotations = {
          # Roll on config drift (e.g. when local.exitnode_names changes
          # because a new wg-*.conf was added). Reloader would also catch it,
          # but keeping the explicit hash keeps the dependency obvious.
          "haproxy-config-hash" = sha1(kubernetes_config_map.exitnode_haproxy_config.data["haproxy.cfg"])
          # Roll the pod when tls-rotator updates the cert in Vault and CSI
          # syncs the new bytes into the exitnode-haproxy-tls k8s secret.
          "secret.reloader.stakater.com/reload" = "exitnode-haproxy-tls"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.exitnode.metadata[0].name

        # Assemble combined PEM for haproxy's `ssl crt` directive. CSI writes
        # the cert + key as separate files (tls_crt, tls_key) into this
        # container's mount; haproxy needs them concatenated into one file.
        #
        # Mounting the CSI volume here (rather than reading from the synced
        # kubernetes.io/tls secret) avoids a bootstrap deadlock: the synced
        # secret only materializes once at least one pod mounts the CSI
        # volume in this namespace, so the init container has to be the
        # mount-trigger itself on first pod start.
        #
        # Reloader watches the synced exitnode-haproxy-tls secret (see pod
        # annotation above) and rolls the pod on rotation, which re-runs
        # this init with the fresh cert.
        init_container {
          name              = "cert-init"
          image             = var.image_haproxy
          image_pull_policy = "IfNotPresent"
          command           = ["/bin/sh", "-c"]
          args = [
            "cat /csi/tls_crt /csi/tls_key > /tls-combined/combined.pem && chmod 600 /tls-combined/combined.pem"
          ]

          volume_mount {
            name       = "secrets-store"
            mount_path = "/csi"
            read_only  = true
          }
          volume_mount {
            name       = "tls-combined"
            mount_path = "/tls-combined"
          }

          resources {
            requests = { cpu = "10m", memory = "8Mi" }
            limits   = { cpu = "100m", memory = "32Mi" }
          }
        }

        container {
          name              = "haproxy"
          image             = var.image_haproxy
          image_pull_policy = "IfNotPresent"

          # Stock haproxy image's ENTRYPOINT runs `haproxy -f
          # /usr/local/etc/haproxy/haproxy.cfg`, so just mounting the file is
          # enough — no command override.

          port {
            container_port = 8888
            name           = "http-proxy"
            protocol       = "TCP"
          }

          port {
            container_port = 8889
            name           = "health"
            protocol       = "TCP"
          }

          port {
            container_port = 443
            name           = "https-proxy"
            protocol       = "TCP"
          }

          volume_mount {
            name       = "config"
            mount_path = "/usr/local/etc/haproxy/haproxy.cfg"
            sub_path   = "haproxy.cfg"
            read_only  = true
          }

          volume_mount {
            name       = "tls-combined"
            mount_path = "/etc/haproxy/certs"
            read_only  = true
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8889
            }
            initial_delay_seconds = 5
            period_seconds        = 30
            timeout_seconds       = 3
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8889
            }
            initial_delay_seconds = 2
            period_seconds        = 10
            timeout_seconds       = 3
          }

          resources {
            requests = { cpu = "10m", memory = "16Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        # Tailscale sidecar — joins the tailnet as exitnode-haproxy under
        # exit_node_user. NOT --advertise-exit-node: haproxy is a plain
        # TCP forwarder on :8888, not an OS-level exit node.
        container {
          name  = "tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }

          env {
            name  = "TS_KUBE_SECRET"
            value = kubernetes_secret.exitnode_haproxy_tailscale_state.metadata[0].name
          }

          env {
            name  = "TS_USERSPACE"
            value = "false"
          }

          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.exitnode_haproxy_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }

          env {
            name  = "TS_HOSTNAME"
            value = "exitnode-haproxy"
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
          name = "config"
          config_map {
            name = kubernetes_config_map.exitnode_haproxy_config.metadata[0].name
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

        # Holds the combined-PEM file produced by cert-init.
        volume {
          name = "tls-combined"
          empty_dir {}
        }

        # CSI mount drives both: (a) direct read by cert-init from
        # /csi/tls_{crt,key}, and (b) reconcile of the SecretProviderClass
        # which syncs the kubernetes.io/tls secret that Reloader watches.
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.exitnode_haproxy_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment.exitnode,
  ]
}

resource "kubernetes_service" "exitnode_haproxy" {
  metadata {
    name      = "exitnode-haproxy"
    namespace = kubernetes_namespace.exitnode.metadata[0].name
    labels = {
      app                      = "exitnode-haproxy"
      "app.kubernetes.io/name" = "exitnode-haproxy"
    }
  }

  spec {
    selector = { app = "exitnode-haproxy" }
    type     = "ClusterIP"

    port {
      name        = "http-proxy"
      port        = 8888
      target_port = 8888
      protocol    = "TCP"
    }

    port {
      name        = "health"
      port        = 8889
      target_port = 8889
      protocol    = "TCP"
    }
  }
}
