terraform {
  required_providers {
    grafana = {
      source = "grafana/grafana"
    version = "~> 4.0" }
  }
}


provider "grafana" {
  url  = "https://${var.grafana_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  auth = "${var.grafana_admin_user}:${data.terraform_remote_state.monitoring.outputs.grafana_admin_password}"
}

# Created via config map
data "grafana_data_source" "prometheus" {
  name = "Prometheus"
}


locals {
  dashboards = {
    "homelab-overview"   = "../data/dashboards/homelab-overview-v2.json"
    "kube-state-metrics" = "../data/dashboards/akash-devops-primefocus-objh.json"
    "k8s-global"         = "../data/dashboards/k8s_views_global.json"
    "k8s-nodes"          = "../data/dashboards/k8s_views_nodes.json"
    "k8s-pods"           = "../data/dashboards/k8s_views_pods.json"
    "node-exporter"      = "../data/dashboards/rYdddlPWk.json"
    "openwrt"            = "../data/dashboards/fLi0yXAWk.json"
  }
}

resource "grafana_dashboard" "managed" {
  for_each    = local.dashboards
  config_json = file(each.value)
}

resource "grafana_message_template" "ntfy" {
  name = "ntfy-payload"
  template = chomp(<<-EOT
{{ define "ntfy.payload" -}}
{{ range .Alerts -}}
{{ if eq .Status "resolved" }}✅ Resolved: {{ .Labels.alertname }}
{{ .Annotations.summary }}
{{ else }}🔥 {{ .Labels.alertname }}
{{ .Annotations.summary }}
{{ end }}
{{ end -}}
{{- end }}
EOT
  )
}

resource "grafana_mute_timing" "overnight" {
  name = "overnight"
  intervals {
    times {
      start = "00:00"
      end   = "09:00"
    }
    location = "America/Chicago"
  }
}


resource "grafana_contact_point" "ntfy" {
  name = "ntfy-homelab"

  webhook {
    url                 = "https://${var.ntfy_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}/${var.ntfy_alert_topic}"
    http_method         = "POST"
    basic_auth_user     = "grafana"
    basic_auth_password = data.terraform_remote_state.monitoring.outputs.ntfy_grafana_password

    payload {
      template = "{{ template \"ntfy.payload\" . }}"
    }
  }
}
resource "grafana_notification_policy" "default" {
  contact_point   = grafana_contact_point.ntfy.name
  group_by        = ["..."]
  group_wait      = "10s"
  group_interval  = "30s"
  repeat_interval = "4h"

  policy {
    contact_point = grafana_contact_point.ntfy.name
    group_by      = ["..."]
    mute_timings  = [grafana_mute_timing.overnight.name]
  }
}

resource "grafana_folder" "alerts" {
  title = "Infrastructure Alerts"
}

resource "grafana_rule_group" "pod_health" {
  name             = "pod-health"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 10

  rule {
    name          = "Pod Not Ready"
    condition     = "C"
    for           = "10s"
    no_data_state = "OK"

    annotations = {
      summary     = "Pod {{ $labels.namespace }}/{{ $labels.pod }} is not ready"
      description = "Pod {{ $labels.pod }} in namespace {{ $labels.namespace }} has been not ready for more than 3 minutes."
    }

    labels = {
      severity = "warning"
    }

    data {
      ref_id         = "A"
      datasource_uid = data.grafana_data_source.prometheus.uid

      relative_time_range {
        from = 300
        to   = 0
      }

      model = jsonencode({
        expr         = "kube_pod_status_ready{condition=\"true\"} == 0 unless on(pod, namespace) kube_pod_status_phase{phase=~\"Succeeded|Failed\"} == 1"
        interval     = ""
        legendFormat = "{{ `{{ namespace }}` }}/{{ `{{ pod }}` }}"
        refId        = "A"
      })
    }

    data {
      ref_id         = "B"
      datasource_uid = "-100"

      relative_time_range {
        from = 0
        to   = 0
      }

      model = jsonencode({
        type       = "reduce"
        expression = "A"
        reducer    = "last"
        refId      = "B"
      })
    }

    data {
      ref_id         = "C"
      datasource_uid = "-100"

      relative_time_range {
        from = 0
        to   = 0
      }

      model = jsonencode({
        type       = "threshold"
        expression = "B"
        refId      = "C"
        conditions = [{
          evaluator = {
            type   = "lt"
            params = [1]
          }
        }]
      })
    }
  }
}
