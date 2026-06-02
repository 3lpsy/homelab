# BuildKit Job for the opencode `web` image.
#
# Pushes ${local.thunderbolt_registry}/opencode:latest. Rebuilds keyed
# off the Dockerfile hash, so a steady-state apply is a no-op.

module "opencode_build" {
  source = "./../templates/buildkit-job"

  name      = "opencode"
  image_ref = local.opencode_image

  context_files = {
    "Dockerfile"   = file("${path.module}/../data/images/opencode/Dockerfile")
    "entrypoint.sh" = file("${path.module}/../data/opencode/entrypoint.sh")
  }

  resources = {
    requests = { cpu = "200m", memory = "512Mi" }
    limits   = { cpu = "2", memory = "2Gi" }
  }
  timeout = "10m"

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}
