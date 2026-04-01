# Monitoring Configuration

Configures Grafana after the monitoring stack is deployed. Connects to Grafana via the Grafana Terraform provider over Tailscale.

## What it manages

- **Dashboards** -- provisioned from JSON files in `data/dashboards/`. Sources noted in `dashboards.tf`.

## Files

- `dashboards.tf` -- Prometheus datasource lookup and dashboard resources.
- `main.tf` -- Grafana provider config.

## Gotchas

- Depends on `monitoring` being fully applied first. The Grafana admin password is read from monitoring's state output.
