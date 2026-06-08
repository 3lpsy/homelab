# BuildKit Job for the Forgejo Actions runner image.
#
# Pushes ${local.git_runner_image}. Rebuilds keyed off the Dockerfile +
# script hashes, so a steady-state apply is a no-op. Mirrors
# services/opencode-jobs.tf.

module "git_runner_build" {
  source = "./../templates/buildkit-job"

  name      = "git-runner"
  image_ref = local.git_runner_image

  context_files = {
    "Dockerfile"       = file("${path.module}/../data/images/git-runner/Dockerfile")
    "entrypoint.sh"    = file("${path.module}/../data/images/git-runner/entrypoint.sh")
    "register.sh"      = file("${path.module}/../data/images/git-runner/register.sh")
    "register-init.sh" = file("${path.module}/../data/images/git-runner/register-init.sh")
  }

  build_args = {
    RUNNER_VERSION = var.git_runner_version
  }

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}

# BuildKit Job for the CI job image (the `ci-podman` runner label). Podman +
# Node, built FROM the official podman image — replaces the upstream catthehacker
# image. Runs PRIVILEGED inside the rootless runner for podman-in-podman; see
# data/images/ci-podman/Dockerfile + config.yaml.tpl.
module "ci_podman_build" {
  source = "./../templates/buildkit-job"

  name      = "ci-podman"
  image_ref = local.ci_podman_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/ci-podman/Dockerfile")
  }

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}
