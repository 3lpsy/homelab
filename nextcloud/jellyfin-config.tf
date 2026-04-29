resource "kubernetes_config_map" "jellyfin_nginx_config" {
  metadata {
    name      = "jellyfin-nginx-config"
    namespace = kubernetes_namespace.jellyfin.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/jellyfin.nginx.conf.tpl", {
      server_domain = "${var.jellyfin_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
    })
  }
}
