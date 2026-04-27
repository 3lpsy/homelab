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
        }
      }

      spec {
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

          volume_mount {
            name       = "config"
            mount_path = "/usr/local/etc/haproxy/haproxy.cfg"
            sub_path   = "haproxy.cfg"
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

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.exitnode_haproxy_config.metadata[0].name
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
