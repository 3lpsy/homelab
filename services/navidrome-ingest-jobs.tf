module "navidrome_ingest_build" {
  source = "./../templates/buildkit-job"

  name      = "navidrome-ingest"
  image_ref = local.navidrome_ingest_image

  context_files = {
    "Dockerfile"             = file("${path.module}/../data/images/navidrome-ingest/Dockerfile")
    "worker.py"              = file("${path.module}/../data/images/navidrome-ingest/worker.py")
    "youtube_lookup.py"      = file("${path.module}/../data/images/navidrome-ingest/youtube_lookup.py")
    "test_worker.py"         = file("${path.module}/../data/images/navidrome-ingest/test_worker.py")
    "test_youtube_lookup.py" = file("${path.module}/../data/images/navidrome-ingest/test_youtube_lookup.py")
  }

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}
