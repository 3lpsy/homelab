data "grafana_data_source" "prometheus" {
  name = "Prometheus"
}

locals {
  dashboards = {
    "homelab-overview" = "../data/dashboards/homelab-overview-v2.json"
    # grafana.com/dashboards/21742
    "kube-state-metrics" = "../data/dashboards/akash-devops-primefocus-objh.json"
    # grafana.com/dashboards/15757
    "k8s-global" = "../data/dashboards/k8s_views_global.json"
    # grafana.com/dashboards/15759
    "k8s-nodes" = "../data/dashboards/k8s_views_nodes.json"
    # grafana.com/dashboards/15760
    "k8s-pods" = "../data/dashboards/k8s_views_pods.json"
    # grafana.com/dashboards/1860
    "node-exporter" = "../data/dashboards/rYdddlPWk.json"
    # grafana.com/dashboards/11147
    "openwrt" = "../data/dashboards/fLi0yXAWk.json"
    # artemis 2× R9700 via ROCm device-metrics-exporter
    "amd-gpu" = "../data/dashboards/amd-gpu.json"
  }
}

resource "grafana_dashboard" "managed" {
  for_each    = local.dashboards
  config_json = file(each.value)
}

# Default landing page for every user in the org. New OIDC users hit
# homelab-overview instead of Grafana's empty Welcome splash.
resource "grafana_organization_preferences" "default" {
  home_dashboard_uid = grafana_dashboard.managed["homelab-overview"].uid
  theme              = "dark"
  timezone           = "browser"
}
