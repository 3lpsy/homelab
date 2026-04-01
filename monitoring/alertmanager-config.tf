resource "kubernetes_config_map" "alertmanager_config" {
  metadata {
    name      = "alertmanager-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "alertmanager.yml" = templatefile("${path.module}/../data/prometheus/alertmanager.yml.tpl", {
      bridge_url    = "http://localhost:8085/alertmanager/pod-state"
      ntfy_username = "prometheus"
      ntfy_password = random_password.ntfy_user_passwords["prometheus"].result
    })
  }
}
