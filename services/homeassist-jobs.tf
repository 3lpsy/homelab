# In-cluster build pipeline for the homeassist custom image (vanilla HA
# + bundled hass-oidc-auth custom component for Zitadel SSO). Mirror of
# services/nextcloud-jobs.tf — uses templates/buildkit-job, the shared
# `local.buildkit_job_shared`, and rebuilds on Dockerfile hash change.

module "homeassist_build" {
  source = "./../templates/buildkit-job"

  name      = "homeassist"
  image_ref = local.homeassist_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/homeassist/Dockerfile")
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
