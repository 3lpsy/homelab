resource "kubernetes_config_map" "grafana_datasources" {
  metadata {
    name      = "grafana-datasources"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "datasources.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name      = "Prometheus"
        type      = "prometheus"
        url       = "http://prometheus:9090"
        access    = "proxy"
        isDefault = true
      }]
    })
  }
}

resource "kubernetes_config_map" "grafana_dashboard_provisioning" {
  metadata {
    name      = "grafana-dashboard-provisioning"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "dashboards.yaml" = yamlencode({
      apiVersion = 1
      providers = [{
        name            = "default"
        orgId           = 1
        folder          = ""
        type            = "file"
        disableDeletion = false
        editable        = true
        options = {
          path = "/var/lib/grafana/dashboards"
        }
      }]
    })
  }
}

resource "kubernetes_config_map" "grafana_nginx_config" {
  metadata {
    name      = "grafana-nginx-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/grafana.nginx.conf.tpl", {
      server_domain = "${var.grafana_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
    })
  }
}