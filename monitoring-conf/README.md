# Monitoring Configuration

Configures Grafana after the monitoring stack is deployed. Connects to Grafana via the Grafana Terraform provider over Tailscale.

## What it manages

- **Dashboards** -- provisioned from JSON files in `data/dashboards/`. Sources noted in `dashboards.tf`.
- **Alerting** -- contact point (ntfy webhook), notification policy, mute timing (overnight 00:00-09:00 CST), and alert rules.

## Files

- `dashboards.tf` -- Prometheus datasource lookup and dashboard resources.
- `alerting.tf` -- Alert rules, contact point, notification policy, mute timing, message template.
- `main.tf` -- Grafana provider config.

## Gotchas

- Depends on `monitoring` being fully applied first. The Grafana admin password is read from monitoring's state output.
- The "Pod Not Ready" alert excludes completed/failed pods (jobs, cronjobs) so it won't fire on normal pod lifecycle.
- The notification policy's mute timing can only be set on the nested `policy` block, not the root -- this is a provider limitation.
