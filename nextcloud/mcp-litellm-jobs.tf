module "mcp_litellm_build" {
  source = "./../templates/buildkit-job"

  name      = "mcp-litellm"
  image_ref = local.mcp_litellm_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/mcp-litellm/Dockerfile")
    "server.py"  = file("${path.module}/../data/images/mcp-litellm/server.py")
  }

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}
