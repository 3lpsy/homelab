resource "kubernetes_config_map" "registry_proxy_config" {
  metadata {
    name      = "registry-proxy-config"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }
  data = {
    "config.yml" = file("${path.module}/../data/registry-proxy/config.yml.tpl")
  }
}

resource "kubernetes_config_map" "registry_proxy_nginx_config" {
  metadata {
    name      = "registry-proxy-nginx-config"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/registry-proxy.nginx.conf.tpl", {
      server_domain = "${var.registry_proxy_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
    })
  }
}
