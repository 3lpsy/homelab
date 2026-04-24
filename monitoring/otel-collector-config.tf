resource "kubernetes_config_map" "otel_collector_config" {
  metadata {
    name      = "otel-collector-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "config.yaml" = templatefile("${path.module}/../data/otel/collector-config.yaml.tpl", {
      namespace       = kubernetes_namespace.monitoring.metadata[0].name
      openobserve_org = var.openobserve_org
    })
  }
}
