module "mcp_prometheus_build" {
  source = "./../templates/buildkit-job"

  name      = "mcp-prometheus"
  image_ref = local.mcp_prometheus_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/mcp-prometheus/Dockerfile")
    "server.py"  = file("${path.module}/../data/images/mcp-prometheus/server.py")
  }

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}
