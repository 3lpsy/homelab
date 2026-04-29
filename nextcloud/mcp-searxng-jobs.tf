module "mcp_searxng_build" {
  source = "./../templates/buildkit-job"

  name      = "mcp-searxng"
  image_ref = local.mcp_searxng_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/mcp-searxng/Dockerfile")
    "server.py"  = file("${path.module}/../data/images/mcp-searxng/server.py")
  }

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}
