resource "kubernetes_config_map" "otel_collector_config" {
  metadata {
    name      = "otel-collector-config"
    namespace = kubernetes_namespace.otel_collector.metadata[0].name
  }

  data = {
    "config.yaml" = templatefile("${path.module}/../data/otel/collector-config.yaml.tpl", {
      # `namespace` here is the OpenObserve namespace, not otel-collector's.
      # The template renders it into the OTLP exporter URL
      # `http://openobserve.${namespace}.svc.cluster.local:5080/...`.
      namespace       = kubernetes_namespace.openobserve.metadata[0].name
      openobserve_org = var.openobserve_org
    })
  }
}
