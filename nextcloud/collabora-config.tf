resource "kubernetes_config_map" "collabora_nginx_config" {
  metadata {
    name      = "collabora-nginx-config"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/collabora.nginx.conf.tpl", {
      server_domain = "${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
    })
  }
}
