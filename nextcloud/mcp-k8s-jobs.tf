# BuildKit job — builds the Python MCP server image. Replaces the previous
# pair of jobs (upstream Go mirror + auth-gate sidecar) with a single Python
# image that bundles the auth middleware. See templates/buildkit-job.

module "mcp_k8s_build" {
  source = "./../templates/buildkit-job"

  name      = "mcp-k8s"
  image_ref = local.mcp_k8s_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/mcp-k8s/Dockerfile")
    "server.py"  = file("${path.module}/../data/images/mcp-k8s/server.py")
  }

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}
