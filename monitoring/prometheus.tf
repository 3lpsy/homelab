# =============================================================================
# Prometheus — Scrapes node-exporter, kube-state-metrics, kubelet/cAdvisor
# Cluster-internal only; Grafana connects via ClusterIP service.
# =============================================================================

# --- RBAC --------------------------------------------------------------------

resource "kubernetes_service_account" "prometheus" {
  metadata {
    name      = "prometheus"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  # Prometheus needs the token to scrape kubelet/cadvisor
  automount_service_account_token = true
}

resource "kubernetes_cluster_role" "prometheus" {
  metadata { name = "prometheus" }

  rule {
    api_groups = [""]
    resources  = ["nodes", "nodes/proxy", "nodes/metrics", "services", "endpoints", "pods"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["extensions", "networking.k8s.io"]
    resources  = ["ingresses"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    non_resource_urls = ["/metrics", "/metrics/cadvisor"]
    verbs             = ["get"]
  }
}

resource "kubernetes_cluster_role_binding" "prometheus" {
  metadata { name = "prometheus" }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.prometheus.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.prometheus.metadata[0].name
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
}

# --- Config ------------------------------------------------------------------

resource "kubernetes_config_map" "prometheus_config" {
  metadata {
    name      = "prometheus-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "prometheus.yml" = <<-EOT
      global:
        scrape_interval: 30s
        evaluation_interval: 30s

      scrape_configs:
        - job_name: 'prometheus'
          static_configs:
            - targets: ['localhost:9090']

        - job_name: 'node-exporter'
          kubernetes_sd_configs:
            - role: node
          relabel_configs:
            - source_labels: [__address__]
              regex: '(.+):(.+)'
              target_label: __address__
              replacement: '$${1}:9100'
            - source_labels: [__meta_kubernetes_node_name]
              target_label: node

        - job_name: 'kube-state-metrics'
          static_configs:
            - targets: ['kube-state-metrics:8080']

        - job_name: 'kubelet'
          scheme: https
          tls_config:
            insecure_skip_verify: true
          bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
          kubernetes_sd_configs:
            - role: node
          relabel_configs:
            - source_labels: [__meta_kubernetes_node_name]
              target_label: node

        - job_name: 'cadvisor'
          scheme: https
          tls_config:
            insecure_skip_verify: true
          bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
          kubernetes_sd_configs:
            - role: node
          relabel_configs:
            - target_label: __metrics_path__
              replacement: /metrics/cadvisor
            - source_labels: [__meta_kubernetes_node_name]
              target_label: node

        - job_name: 'kubernetes-pods'
          kubernetes_sd_configs:
            - role: pod
          relabel_configs:
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
              action: keep
              regex: true
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
              action: replace
              target_label: __metrics_path__
              regex: (.+)
            - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
              action: replace
              regex: ([^:]+)(?::\d+)?;(\d+)
              replacement: $${1}:$${2}
              target_label: __address__
            - source_labels: [__meta_kubernetes_namespace]
              target_label: namespace
            - source_labels: [__meta_kubernetes_pod_name]
              target_label: pod

        # OpenWrt node exporter over Tailscale
        - job_name: 'openwrt'
          scrape_interval: 60s
          static_configs:
            - targets: ['${var.openwrt_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}:9100']
    EOT
  }
}

# --- Storage -----------------------------------------------------------------

resource "kubernetes_persistent_volume_claim" "prometheus_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "prometheus-data"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.prometheus_storage_size
      }
    }
  }
  wait_until_bound = false
}

# --- Deployment --------------------------------------------------------------

resource "kubernetes_deployment" "prometheus" {
  metadata {
    name      = "prometheus"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = { app = "prometheus" }
    }

    template {
      metadata {
        labels = { app = "prometheus" }
      }

      spec {
        service_account_name            = kubernetes_service_account.prometheus.metadata[0].name
        automount_service_account_token = true

        init_container {
          name  = "fix-permissions"
          image = "busybox:latest"
          command = [
            "sh", "-c",
            "chown -R 65534:65534 /prometheus"
          ]
          volume_mount {
            name       = "prometheus-data"
            mount_path = "/prometheus"
          }
        }

        # Tailscale sidecar — joins tailnet as "prometheus" user
        container {
          name  = "tailscale"
          image = "tailscale/tailscale:latest"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "prometheus-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.prometheus_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = "prometheus"
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

        container {
          name  = "prometheus"
          image = "prom/prometheus:latest"

          args = [
            "--config.file=/etc/prometheus/prometheus.yml",
            "--storage.tsdb.path=/prometheus",
            "--storage.tsdb.retention.time=${var.prometheus_retention}",
            "--web.enable-lifecycle",
          ]

          port {
            container_port = 9090
            name           = "http"
          }

          volume_mount {
            name       = "prometheus-config"
            mount_path = "/etc/prometheus"
          }
          volume_mount {
            name       = "prometheus-data"
            mount_path = "/prometheus"
          }

          resources {
            requests = { cpu = "250m", memory = "512Mi" }
            limits   = { cpu = "1000m", memory = "2Gi" }
          }

          liveness_probe {
            http_get {
              path = "/-/healthy"
              port = 9090
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/-/ready"
              port = 9090
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        volume {
          name = "prometheus-config"
          config_map {
            name = kubernetes_config_map.prometheus_config.metadata[0].name
          }
        }
        volume {
          name = "prometheus-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.prometheus_data.metadata[0].name
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
}

# --- Service -----------------------------------------------------------------

resource "kubernetes_service" "prometheus" {
  metadata {
    name      = "prometheus"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    selector = { app = "prometheus" }

    port {
      name        = "http"
      port        = 9090
      target_port = 9090
    }
  }
}
