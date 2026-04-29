module "mcp_filesystem_build" {
  source = "./../templates/buildkit-job"

  name      = "mcp-filesystem"
  image_ref = local.mcp_filesystem_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/mcp-filesystem/Dockerfile")
    "server.py"  = file("${path.module}/../data/images/mcp-filesystem/server.py")
  }

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}

module "mcp_filesystem" {
  source = "../templates/mcp-server"

  name                         = "mcp-filesystem"
  namespace                    = kubernetes_namespace.mcp.metadata[0].name
  image                        = local.mcp_filesystem_image
  build_job_name               = module.mcp_filesystem_build.job_name
  service_account_name         = kubernetes_service_account.mcp.metadata[0].name
  image_pull_secret_name       = kubernetes_secret.mcp_registry_pull_secret.metadata[0].name
  shared_secret_provider_class = kubernetes_manifest.mcp_shared_secret_provider.manifest.metadata.name
  log_level                    = var.mcp_filesystem_log_level
  image_busybox                = var.image_busybox

  pod_fs_group = 1000
  data_volume = {
    pvc_name   = kubernetes_persistent_volume_claim.mcp_data.metadata[0].name
    mount_path = "/data"
  }

  extra_env = [
    { name = "MCP_DATA_ROOT", value = "/data" },
    {
      name              = "MCP_PATH_SALT"
      value_from_secret = { name = "mcp-auth", key = "path_salt" }
    },
  ]
}
