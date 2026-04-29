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
