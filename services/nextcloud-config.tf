resource "kubernetes_config_map" "nginx_config" {
  metadata {
    name      = "nginx-config"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/nextcloud.nginx.conf.tpl", {
      server_domain = "${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
    })
  }
}
