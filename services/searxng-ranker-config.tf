resource "kubernetes_config_map" "searxng_ranker_script" {
  metadata {
    name      = "searxng-ranker-script"
    namespace = kubernetes_namespace.searxng.metadata[0].name
  }

  data = {
    "searxng-ranker.py" = file("${path.module}/../data/searxng/ranker.py")
  }
}
