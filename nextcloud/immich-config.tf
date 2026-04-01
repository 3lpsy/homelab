resource "kubernetes_config_map" "immich_nginx_config" {
  metadata {
    name      = "immich-nginx-config"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/immich.nginx.conf.tpl", {
      server_domain = "${var.immich_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
    })
  }
}
