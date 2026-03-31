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
  group_wait      = "30s"
  group_interval  = "5m"
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
  interval_seconds = 60

  rule {
    name          = "Pod Not Ready"
    condition     = "C"
    for           = "3m"
    no_data_state = "OK"

    annotations = {
      summary = "Pod {{ $labels.namespace }}/{{ $labels.pod }} is not ready"
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
