# BuildKit job for the tls-rotator image. Uses the shared
# templates/buildkit-job module — context covers Dockerfile + rotate.py so a
# change to either triggers a rebuild via the module's content hash.

locals {
  tls_rotator_image = "${local.thunderbolt_registry}/tls-rotator:latest"
}

module "tls_rotator_build" {
  source = "./../templates/buildkit-job"

  name      = "tls-rotator"
  image_ref = local.tls_rotator_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/tls-rotator/Dockerfile")
    "rotate.py"  = file("${path.module}/../data/images/tls-rotator/rotate.py")
  }

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}
