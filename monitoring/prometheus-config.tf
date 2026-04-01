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