resource "kubernetes_config_map" "mcp_searxng_nginx_config" {
  metadata {
    name      = "mcp-searxng-nginx-config"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }

  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/mcp-searxng.nginx.conf.tpl", {
      server_domain = local.mcp_searxng_fqdn
      path_prefix   = local.mcp_searxng_path
    })
  }
}
