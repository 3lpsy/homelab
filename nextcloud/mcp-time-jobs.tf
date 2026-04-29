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
