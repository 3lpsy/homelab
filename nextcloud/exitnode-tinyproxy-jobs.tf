# In-cluster build pipeline for the exitnode-tinyproxy image. Uses the shared
# templates/buildkit-job module — see nextcloud/builder-buildkitd-config.tf
# for the buildkitd.toml mirror config and `local.buildkit_job_shared`.
module "exitnode_tinyproxy_build" {
  source = "./../templates/buildkit-job"

  name      = "exitnode-tinyproxy"
  image_ref = local.exitnode_tinyproxy_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/tinyproxy/Dockerfile")
  }

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}
