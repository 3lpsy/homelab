resource "kubernetes_daemonset" "otel_collector" {
  metadata {
    name      = "otel-collector"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { app = "otel-collector" }
  }

  spec {
    selector {
      match_labels = { app = "otel-collector" }
    }

    template {
      metadata {
        labels = { app = "otel-collector" }
        annotations = {
          "otel-collector-config-hash"          = sha1(kubernetes_config_map.otel_collector_config.data["config.yaml"])
          "secret.reloader.stakater.com/reload" = "otel-openobserve-auth"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.otel_collector.metadata[0].name
        host_network         = false

        image_pull_secrets {
          name = kubernetes_secret.otel_registry_pull_secret.metadata[0].name
        }

        # systemd-journal gid on the K3s host. Grants /var/log/journal read
        # without running the collector as root.
        security_context {
          run_as_user          = 10001
          run_as_group         = 10001
          supplemental_groups  = [190]
        }

        toleration {
          operator = "Exists"
        }

        container {
          name = "otel-collector"
          # Custom image built by nextcloud/otel-collector-jobs.tf (alpine +
          # systemd + upstream binary). Lets the journald receiver work.
          image = var.image_otel_collector != "" ? var.image_otel_collector : "${var.registry_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}/otel-collector:latest"

          args = [
            "--config=/etc/otelcol/config.yaml",
          ]

          env {
            name = "K8S_NODE_NAME"
            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }
          env {
            name = "OO_AUTH"
            value_from {
              secret_key_ref {
                name     = "otel-openobserve-auth"
                key      = "OO_AUTH"
                optional = true
              }
            }
          }

          port {
            container_port = 13133
            name           = "health"
          }

          volume_mount {
            name       = "otel-collector-config"
            mount_path = "/etc/otelcol"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
          volume_mount {
            name              = "var-log-pods"
            mount_path        = "/var/log/pods"
            read_only         = true
            mount_propagation = "HostToContainer"
          }
          volume_mount {
            name              = "var-log-containers"
            mount_path        = "/var/log/containers"
            read_only         = true
            mount_propagation = "HostToContainer"
          }
          volume_mount {
            name       = "var-log-journal"
            mount_path = "/var/log/journal"
            read_only  = true
          }
          volume_mount {
            name       = "etc-machine-id"
            mount_path = "/etc/machine-id"
            read_only  = true
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 13133
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 13133
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }

        volume {
          name = "otel-collector-config"
          config_map {
            name = kubernetes_config_map.otel_collector_config.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.otel_collector_secret_provider.manifest.metadata.name
            }
          }
        }
        volume {
          name = "var-log-pods"
          host_path { path = "/var/log/pods" }
        }
        volume {
          name = "var-log-containers"
          host_path { path = "/var/log/containers" }
        }
        volume {
          name = "var-log-journal"
          host_path { path = "/var/log/journal" }
        }
        volume {
          name = "etc-machine-id"
          host_path { path = "/etc/machine-id" }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.otel_collector_secret_provider,
    kubernetes_deployment.openobserve,
  ]
}
