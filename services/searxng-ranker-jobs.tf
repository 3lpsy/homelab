# BuildKit job for the searxng-ranker image. Uses the shared
# templates/buildkit-job module — see services/builder-buildkitd-config.tf
# for the buildkitd.toml mirror config and `local.buildkit_job_shared`.
module "searxng_ranker_build" {
  source = "./../templates/buildkit-job"

  name      = "searxng-ranker"
  image_ref = local.searxng_ranker_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/searxng-ranker/Dockerfile")
  }

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}
