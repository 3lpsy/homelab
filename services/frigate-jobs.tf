# In-cluster build of the Frigate ONNX model artifact. Same BuildKit
# pattern as every other custom image in this deployment — Dockerfile
# hash keys the rebuild trigger, so editing data/images/frigate-model/
# Dockerfile is the only knob to bump model versions or swap to a
# different YOLOv9 size. See data/images/frigate-model/Dockerfile for
# the export procedure and frigate.tf's `seed-model` init container for
# how the resulting /model.onnx lands in the config PVC.
module "frigate_model_build" {
  source = "./../templates/buildkit-job"

  name      = "frigate-model"
  image_ref = local.frigate_model_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/frigate-model/Dockerfile")
  }

  shared = local.buildkit_job_shared

  # YOLOv9 export pulls torch + the WongKinYiu repo + the .pt weights and
  # then runs ONNX conversion — easily 10-15 minutes on first build,
  # cached layers cut subsequent builds to a couple minutes.
  timeout = "30m"

  # torch's pip install peaks around 3 GB resident; the buildkit-job
  # default limit (2 GB) OOM-kills. 6 GB gives headroom for both the
  # install and the export step which loads the .pt checkpoint into
  # memory before serializing to ONNX.
  resources = {
    requests = { cpu = "500m", memory = "1Gi" }
    limits   = { cpu = "4", memory = "6Gi" }
  }

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}
