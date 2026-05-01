# Monitoring Configuration

Post-apply configuration for Grafana. Uses the Grafana Terraform
provider over Tailscale to provision dashboards after the `services`
deployment has brought Grafana up.

## What it manages

- **Dashboards**. Each JSON file in `../data/dashboards/` is mapped to
  a Grafana dashboard resource through the `dashboards` local in
  `dashboards.tf`. The Prometheus data source is looked up by name
  (not created here; Grafana provisions it via its ConfigMap in the
  `services` deployment's monitoring namespace).

Current dashboards: `homelab-overview`, `kube-state-metrics`,
`k8s-global`, `k8s-nodes`, `k8s-pods`, `node-exporter`, `openwrt`.

## Files

- `main.tf` -- Grafana provider config (Tailscale URL, admin auth
  pulled from `services`'s remote state).
- `dashboards.tf` -- Prometheus datasource lookup, dashboard map,
  `grafana_dashboard` resource.

## Gotchas

- **Depends on `services`**. The Grafana admin password is read
  from `terraform_remote_state.services.outputs.grafana_admin_password`,
  so `services` must be fully applied first.
- **Provider reaches Grafana over Tailscale**. The apply host must be
  on the tailnet and able to resolve the Grafana FQDN.
- **Adding a dashboard**. Drop the JSON file in `../data/dashboards/`,
  add an entry to the `dashboards` local in `dashboards.tf`, and
  re-apply. The key in the map is the stable Grafana UID prefix;
  changing it creates a new dashboard rather than renaming.
