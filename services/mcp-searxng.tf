module "mcp_searxng_build" {
  source = "./../templates/buildkit-job"

  name      = "mcp-searxng"
  image_ref = local.mcp_searxng_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/mcp-searxng/Dockerfile")
    "server.py"  = file("${path.module}/../data/images/mcp-searxng/server.py")
  }
  context_dirs = local.mcp_common_files

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}

module "mcp_searxng" {
  source = "../templates/mcp-server"

  name                         = "mcp-searxng"
  namespace                    = kubernetes_namespace.mcp.metadata[0].name
  image                        = local.mcp_searxng_image
  build_job_name               = module.mcp_searxng_build.job_name
  service_account_name         = kubernetes_service_account.mcp.metadata[0].name
  image_pull_secret_name       = kubernetes_secret.mcp_registry_pull_secret.metadata[0].name
  shared_secret_provider_class = kubernetes_manifest.mcp_shared_secret_provider.manifest.metadata.name
  log_level                    = var.mcp_searxng_log_level
  image_busybox                = var.image_busybox

  # Pin searxng.<hs>.<magic> to the searxng Service ClusterIP so the
  # backend can dial the FQDN (MCP_SEARXNG_URL) and keep using the
  # FQDN-valid TLS cert nginx serves at :443 — no tailnet round-trip.
  host_aliases = [
    {
      ip        = kubernetes_service.searxng.spec[0].cluster_ip
      hostnames = ["${var.searxng_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"]
    },
  ]

  extra_env = [
    {
      name  = "MCP_SEARXNG_URL"
      value = "https://${var.searxng_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
    },
  ]
}
