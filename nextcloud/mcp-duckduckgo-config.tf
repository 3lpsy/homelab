resource "kubernetes_config_map" "mcp_duckduckgo_nginx_config" {
  metadata {
    name      = "mcp-duckduckgo-nginx-config"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }

  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/mcp-duckduckgo.nginx.conf.tpl", {
      server_domain = local.mcp_duckduckgo_fqdn
      path_prefix   = local.mcp_duckduckgo_path
    })
  }
}
