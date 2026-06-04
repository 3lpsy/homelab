# In-cluster build for the frigate-model artifact image (YOLOv9 → ONNX). Uses
# the shared templates/buildkit-job module (see services/builder-buildkitd-config.tf
# for buildkitd.toml + local.buildkit_job_shared). The image is a single-file
# carrier for /model.onnx; the `seed-model` init container in services/frigate.tf
# copies it into the frigate-config PVC's model_cache/ on every pod start.
#
# Frigate's ONNX detector needs a model provided (no auto-download on ROCm), so
# we build + push our own. Rebuild triggers on the Dockerfile hash (and the
# build_args via the module's context hash), so bumping MODEL_SIZE retags + rolls.
locals {
  frigate_model_image = "${local.thunderbolt_registry}/frigate-model:latest"
}

module "frigate_model_build" {
  source = "./../templates/buildkit-job"

  name      = "frigate-model"
  image_ref = local.frigate_model_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/frigate-model/Dockerfile")
  }

  # YOLOv9 variant + input size for the R9700 detector. `c` (full YOLOv9) is a
  # large accuracy gain over the iGPU-era `t`; the gfx1201 GPU has headroom.
  # Bump MODEL_SIZE to `e` for max accuracy. These flow into the Dockerfile ARGs
  # and the module folds them into the rebuild hash.
  build_args = {
    MODEL_SIZE       = "c"
    IMG_SIZE         = "640"
    UV_EXCLUDE_NEWER = var.pip_proxy_cooldown_value
  }

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}
