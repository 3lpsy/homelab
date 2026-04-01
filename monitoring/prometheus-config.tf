resource "kubernetes_config_map" "prometheus_config" {
  metadata {
    name      = "prometheus-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "prometheus.yml" = templatefile("${path.module}/../data/prometheus/prometheus.yml.tpl", {
      openwrt_target = "${var.openwrt_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}:9100"
    })

    "alert-rules.yml" = file("${path.module}/../data/prometheus/alert-rules.yml.tpl")
  }
}