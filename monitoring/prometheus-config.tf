resource "kubernetes_config_map" "prometheus_config" {
  metadata {
    name      = "prometheus-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "prometheus.yml" = templatefile("${path.module}/../data/prometheus/prometheus.yml.tpl", {
      prometheus_target       = "localhost:9090"
      alertmanager_target     = "localhost:9093"
      kube_state_metrics_target = "kube-state-metrics:8080"
      openwrt_target          = "${var.openwrt_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}:9100"
    })

    "alert-rules.yml" = file("${path.module}/../data/prometheus/alert-rules.yml.tpl")
  }
}