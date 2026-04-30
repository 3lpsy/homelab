resource "kubernetes_config_map" "ingest_syncthing_nginx_config" {
  metadata {
    name      = "syncthing-nginx-config"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/syncthing.nginx.conf.tpl", {
      server_domain = "${var.ingest_syncthing_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
    })
  }
}

resource "kubernetes_config_map" "ingest_syncthing_config_template" {
  metadata {
    name      = "syncthing-config-template"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }
  data = {
    "config.xml" = templatefile("${path.module}/../data/syncthing/config.xml.tpl", {
      gui_user               = "admin"
      trusted_devices        = var.ingest_syncthing_trusted_devices
      tailnet_hostnames      = var.tailnet_device_hostnames
      headscale_subdomain    = var.headscale_subdomain
      headscale_magic_domain = var.headscale_magic_domain
    })
  }
}

resource "kubernetes_config_map" "ingest_syncthing_render_script" {
  metadata {
    name      = "syncthing-render-script"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }
  data = {
    "render-config.sh" = templatefile("${path.module}/../data/syncthing/syncthing-config-render.sh.tpl", {
      gui_user = "admin"
    })
  }
}
