# Searxng per-engine proxy ranker daemon. Periodically probes each
# (upstream-engine × exit-node-proxy) pair, rewrites the searxng-config
# ConfigMap with ranked per-engine proxy lists, and triggers a rolling
# restart of the searxng Deployment via pod-template annotation.

resource "kubernetes_deployment" "searxng_ranker" {
  # Fail fast if the WG dir is empty — otherwise EXITNODE_PROXIES renders
  # as the empty string, the ranker script exits immediately with
  # "no EXITNODE_PROXIES configured", and the kubernetes provider blocks
  # for the full rollout timeout waiting on a pod that never gets Ready.
  lifecycle {
    precondition {
      condition     = length(local.exitnode_names) > 0
      error_message = "No *.conf files found in var.wireguard_config_dir (${var.wireguard_config_dir}); searxng-ranker requires at least one exit node."
    }
  }

  # Surface misconfigs in ~3m instead of the 10m k8s-provider default.
  timeouts {
    create = "3m"
    update = "3m"
  }

  metadata {
    name      = "searxng-ranker"
    namespace = kubernetes_namespace.searxng.metadata[0].name
    labels = {
      app = "searxng-ranker"
    }
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "searxng-ranker"
      }
    }

    template {
      metadata {
        labels = {
          app = "searxng-ranker"
        }
        annotations = {
          "script-hash" = sha1(kubernetes_config_map.searxng_ranker_script.data["searxng-ranker.py"])
        }
      }

      spec {
        service_account_name = kubernetes_service_account.searxng_ranker.metadata[0].name

        image_pull_secrets {
          name = kubernetes_secret.searxng_registry_pull_secret.metadata[0].name
        }

        container {
          name              = "searxng-ranker"
          image             = local.searxng_ranker_image
          image_pull_policy = "Always"

          env {
            name = "EXITNODE_PROXIES"
            value = join(" ", [
              for k in sort(keys(local.exitnode_names)) :
              "http://exitnode-${k}-proxy.exitnode.svc.cluster.local:8888"
            ])
          }

          env {
            name  = "SEARXNG_NAMESPACE"
            value = kubernetes_namespace.searxng.metadata[0].name
          }

          env {
            name  = "SEARXNG_CONFIGMAP"
            value = "searxng-config"
          }

          env {
            name  = "SEARXNG_DEPLOYMENT"
            value = "searxng"
          }

          env {
            name  = "RANKER_INTERVAL_SECONDS"
            value = "1800"
          }

          env {
            name  = "RANKER_PROBE_TIMEOUT_SECONDS"
            value = "8"
          }

          env {
            name  = "RANKER_TOP_N"
            value = "8"
          }

          env {
            name  = "RANKER_EWMA_ALPHA"
            value = "0.3"
          }

          port {
            container_port = 8090
            name           = "health"
          }

          volume_mount {
            name       = "ranker-script"
            mount_path = "/app"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "192Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8090
            }
            initial_delay_seconds = 15
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8090
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }

        volume {
          name = "ranker-script"
          config_map {
            name = kubernetes_config_map.searxng_ranker_script.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.searxng_ranker_build,
    kubernetes_role_binding.searxng_ranker,
    kubernetes_deployment.searxng,
  ]
}
