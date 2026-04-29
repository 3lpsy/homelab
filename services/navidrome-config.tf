resource "kubernetes_config_map" "navidrome_nginx_config" {
  metadata {
    name      = "navidrome-nginx-config"
    namespace = kubernetes_namespace.navidrome.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/navidrome.nginx.conf.tpl", {
      server_domain = "${var.navidrome_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
    })
  }
}
