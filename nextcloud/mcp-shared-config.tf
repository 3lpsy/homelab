resource "kubernetes_config_map" "mcp_shared_nginx_config" {
  metadata {
    name      = "mcp-shared-nginx-config"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }

  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/mcp-shared.nginx.conf.tpl", {
      server_domain = local.mcp_shared_fqdn
      services      = local.mcp_backend_services
    })
  }
}
