resource "kubernetes_config_map" "registry_dockerio_config" {
  metadata {
    name      = "registry-dockerio-config"
    namespace = kubernetes_namespace.registry_dockerio.metadata[0].name
  }
  data = {
    "config.yml" = file("${path.module}/../data/registry-dockerio/config.yml.tpl")
  }
}

resource "kubernetes_config_map" "registry_dockerio_nginx_config" {
  metadata {
    name      = "registry-dockerio-nginx-config"
    namespace = kubernetes_namespace.registry_dockerio.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/registry-dockerio.nginx.conf.tpl", {
      server_domain = "${var.registry_dockerio_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
    })
  }
}
