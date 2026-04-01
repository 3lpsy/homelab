resource "kubernetes_config_map" "pihole_nginx_config" {
  metadata {
    name      = "pihole-nginx-config"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/pihole.nginx.conf.tpl", {
      server_domain = "${var.pihole_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
    })
  }
}
