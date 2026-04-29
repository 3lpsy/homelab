resource "kubernetes_config_map" "openobserve_env" {
  metadata {
    name      = "openobserve-env"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    ZO_LOCAL_MODE                  = "true"
    ZO_LOCAL_MODE_STORAGE          = "disk"
    ZO_DATA_DIR                    = "/data"
    ZO_HTTP_PORT                   = "5080"
    ZO_GRPC_PORT                   = "5081"
    ZO_COMPACT_DATA_RETENTION_DAYS = tostring(var.openobserve_retention_days)
    ZO_TELEMETRY                   = "false"
    # Drop INFO chatter (flight->search SQL echo + access-log middleware lines
    # that pollute the `pods` stream when searching for "error"). WARN+ still
    # surfaces ingest rejections, schema conflicts, etc.
    RUST_LOG = "warn"
  }
}

resource "kubernetes_config_map" "openobserve_nginx" {
  metadata {
    name      = "openobserve-nginx"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/openobserve.nginx.conf.tpl", {
      server_domain = "${var.openobserve_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
    })
  }
}
