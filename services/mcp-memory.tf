module "mcp_memory_build" {
  source = "./../templates/buildkit-job"

  name      = "mcp-memory"
  image_ref = local.mcp_memory_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/mcp-memory/Dockerfile")
    "server.py"  = file("${path.module}/../data/images/mcp-memory/server.py")
  }

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}

module "mcp_memory" {
  source = "../templates/mcp-server"

  name                         = "mcp-memory"
  namespace                    = kubernetes_namespace.mcp.metadata[0].name
  image                        = local.mcp_memory_image
  build_job_name               = module.mcp_memory_build.job_name
  service_account_name         = kubernetes_service_account.mcp.metadata[0].name
  image_pull_secret_name       = kubernetes_secret.mcp_registry_pull_secret.metadata[0].name
  shared_secret_provider_class = kubernetes_manifest.mcp_shared_secret_provider.manifest.metadata.name
  log_level                    = var.mcp_memory_log_level
  image_busybox                = var.image_busybox

  # Memory shares the same `mcp_data` PVC as filesystem by design — both
  # sandbox per tenant inside the volume via salted hashes.
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
