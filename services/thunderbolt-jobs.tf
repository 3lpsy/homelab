# In-cluster build pipelines for the thunderbolt frontend and backend images.
# Uses the shared templates/buildkit-job module.
#
# Both Dockerfiles do `git clone` at build time, so the build context only
# needs the Dockerfile itself plus any overlay files the image COPYs
# (frontend: nginx.conf; backend: exa-override.ts). A separate git ref is
# pinned via var.thunderbolt_ref — passed as both a build-arg and as
# `context_hash_extra` so a ref change triggers a rebuild even when nothing
# in the build context changed.
#
# Force a rebuild by touching any context file or bumping var.thunderbolt_ref.
# Old completed Jobs accumulate; clean periodically with:
#   kubectl delete jobs -n builder --field-selector status.successful=1

module "thunderbolt_frontend_build" {
  source = "./../templates/buildkit-job"

  name      = "thunderbolt-frontend"
  image_ref = local.thunderbolt_frontend_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/thunderbolt/frontend/Dockerfile")
    "nginx.conf" = file("${path.module}/../data/images/thunderbolt/frontend/nginx.conf")
  }

  build_args = {
    THUNDERBOLT_REF = var.thunderbolt_ref
  }
  context_hash_extra = var.thunderbolt_ref

  resources = {
    requests = { cpu = "500m", memory = "1Gi" }
    limits   = { cpu = "4", memory = "6Gi" }
  }
  timeout = "20m"

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}

module "thunderbolt_backend_build" {
  source = "./../templates/buildkit-job"

  name      = "thunderbolt-backend"
  image_ref = local.thunderbolt_backend_image

  context_files = {
    "Dockerfile"      = file("${path.module}/../data/images/thunderbolt/backend/Dockerfile")
    "exa-override.ts" = file("${path.module}/../data/images/thunderbolt/backend/exa-override.ts")
  }

  build_args = {
    THUNDERBOLT_REF = var.thunderbolt_ref
  }
  context_hash_extra = var.thunderbolt_ref

  resources = {
    requests = { cpu = "300m", memory = "768Mi" }
    limits   = { cpu = "3", memory = "3Gi" }
  }
  timeout = "20m"

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}
