resource "kubernetes_config_map" "registry_nginx_config" {
  metadata {
    name      = "registry-nginx-config"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/registry.nginx.conf.tpl", {
      server_domain = "${var.registry_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
    })
  }
}
