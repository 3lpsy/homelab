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
    # BuildKit pod startup (resolver wedges under high concurrency).
  ]
}
