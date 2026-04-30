module "ingest_ui_build" {
  source = "./../templates/buildkit-job"

  name      = "ingest-ui"
  image_ref = local.ingest_ui_image

  context_files = {
    "Dockerfile"     = file("${path.module}/../data/images/ingest-ui/Dockerfile")
    "server.py"      = file("${path.module}/../data/images/ingest-ui/server.py")
    "index.html"     = file("${path.module}/../data/images/ingest-ui/index.html")
    "test_server.py" = file("${path.module}/../data/images/ingest-ui/test_server.py")
  }

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}
