resource "kubernetes_config_map" "ingest_ui_nginx_config" {
  metadata {
    name      = "ingest-ui-nginx-config"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/ingest-ui.nginx.conf.tpl", {
      server_domain = "${var.ingest_ui_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
    })
  }
}

resource "kubernetes_config_map" "ingest_ui_htpasswd_script" {
  metadata {
    name      = "ingest-ui-htpasswd-script"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }
  data = {
    "htpasswd-multi.py" = file("${path.module}/../data/scripts/htpasswd-multi.py.tpl")
  }
}
