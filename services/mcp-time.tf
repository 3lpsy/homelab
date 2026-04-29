module "mcp_time_build" {
  source = "./../templates/buildkit-job"

  name      = "mcp-time"
  image_ref = local.mcp_time_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/mcp-time/Dockerfile")
    "server.py"  = file("${path.module}/../data/images/mcp-time/server.py")
  }

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}

module "mcp_time" {
  source = "../templates/mcp-server"

  name                         = "mcp-time"
  namespace                    = kubernetes_namespace.mcp.metadata[0].name
  image                        = local.mcp_time_image
  build_job_name               = module.mcp_time_build.job_name
  service_account_name         = kubernetes_service_account.mcp.metadata[0].name
  image_pull_secret_name       = kubernetes_secret.mcp_registry_pull_secret.metadata[0].name
  shared_secret_provider_class = kubernetes_manifest.mcp_shared_secret_provider.manifest.metadata.name
  log_level                    = var.mcp_time_log_level
  image_busybox                = var.image_busybox

  extra_env = [
    { name = "MCP_DEFAULT_TIMEZONE", value = var.mcp_time_default_timezone },
  ]
}
