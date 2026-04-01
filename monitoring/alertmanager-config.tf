resource "kubernetes_config_map" "alertmanager_config" {
  metadata {
    name      = "alertmanager-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "alertmanager.yml" = templatefile("${path.module}/../data/alertmanager/alertmanager.yml.tpl", {
      ntfy_url      = "https://${var.ntfy_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
      ntfy_topic    = var.ntfy_alert_topic
      ntfy_password = random_password.ntfy_user_passwords["prometheus"].result
    })
  }
}
