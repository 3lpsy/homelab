resource "kubernetes_config_map" "frigate_config" {
  metadata {
    name      = "frigate-config"
    namespace = kubernetes_namespace.frigate.metadata[0].name
  }
  data = {
    # Day-1 config: no cameras, AMD VAAPI hwaccel for decode, CPU detector.
    # When cameras land, edit data/frigate/config.yml.tpl in place and
    # re-apply — Reloader rolls the deployment when the ConfigMap hash
    # changes (config-hash pod annotation in frigate.tf).
    "config.yml" = templatefile("${path.module}/../data/frigate/config.yml.tpl", {})
  }
}

resource "kubernetes_config_map" "frigate_nginx_config" {
  metadata {
    name      = "frigate-nginx-config"
    namespace = kubernetes_namespace.frigate.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/frigate.nginx.conf.tpl", {
      server_domain = "${var.frigate_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
    })
  }
}
