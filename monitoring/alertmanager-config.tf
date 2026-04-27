resource "kubernetes_config_map" "alertmanager_config" {
  metadata {
    name      = "alertmanager-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  # Password is NOT rendered here. alertmanager reads it from
  # /etc/alertmanager-secrets/ntfy_password at startup, mounted via Vault CSI
  # (see vault-prometheus-alertmanager SPC in prometheus-secrets.tf). Keeps
  # the credential out of the ConfigMap so Velero backups never see it.
  data = {
    "alertmanager.yml" = templatefile("${path.module}/../data/prometheus/alertmanager.yml.tpl", {
      bridge_url    = "http://localhost:8085/alertmanager/pod-state"
      ntfy_username = "prometheus"
    })
  }
}
