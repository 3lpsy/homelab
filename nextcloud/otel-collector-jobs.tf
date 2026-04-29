# BuildKit Job for the OpenTelemetry Collector (contrib) image with
# `journalctl` available. Consumed by the OTel DaemonSet in `monitoring/`.
# Uses the shared templates/buildkit-job module.

locals {
  otel_collector_image = "${local.thunderbolt_registry}/otel-collector:latest"
}

module "otel_collector_build" {
  source = "./../templates/buildkit-job"

  name      = "otel-collector"
  image_ref = local.otel_collector_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/otel-collector/Dockerfile")
  }

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}
