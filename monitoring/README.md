# Monitoring

Deploys the monitoring stack into the `monitoring` namespace on K3s.

## Services

- **Prometheus** -- scrapes node-exporter, kube-state-metrics, kubelet/cAdvisor, and an OpenWrt target over Tailscale. Evaluates alert rules and forwards to Alertmanager. Cluster-internal only (ClusterIP).
- **Alertmanager** -- runs as sidecar in the Prometheus pod. Routes alerts to the ntfy-bridge sidecar. Config template in `data/prometheus/alertmanager.yml.tpl`.
- **ntfy-bridge** -- runs as sidecar in the Prometheus pod. Receives Alertmanager webhooks, reformats them into human-readable notifications with emoji and priority, and forwards to Ntfy over Tailscale. Script at `data/scripts/ntfy-bridge.py`.
- **Grafana** -- exposed via Tailscale with Nginx TLS termination. Secrets (admin password, TLS certs) pulled from Vault via CSI driver.
- **Ntfy** -- push notification server. Receives formatted alerts from ntfy-bridge over Tailscale. Also exposed via Tailscale + Nginx TLS.
- **Node Exporter** -- DaemonSet on host network, no sidecar.
- **kube-state-metrics** -- cluster-internal, scraped by Prometheus.

## File layout

Each service is split into up to four files:

| Suffix | Contents |
|---|---|
| `<service>.tf` | Deployment and Service |
| `<service>-secrets.tf` | Service account, RBAC, Headscale pre-auth key, TLS certs, Vault secrets/policy/role, CSI SecretProviderClass |
| `<service>-config.tf` | ConfigMaps (app config, nginx config) |
| `<service>-pvc.tf` | PersistentVolumeClaim |

Node-exporter and kube-state-metrics are small enough to be single files.

## Deployment pattern

Grafana and ntfy follow the same pod structure:

1. Init containers (wait-for-secrets, fix-permissions)
2. Main application container
3. Nginx sidecar for TLS termination
4. Tailscale sidecar for mesh networking

Prometheus skips nginx (cluster-internal only) but has the same tailscale sidecar. Alertmanager and ntfy-bridge run as additional sidecars in the Prometheus pod, sharing its Tailscale interface. Alert flow: Prometheus -> Alertmanager -> ntfy-bridge -> Ntfy (over Tailscale).

## Gotchas

- **Ntfy bcrypt config**: The ntfy server config uses `bcrypt()` which generates a new salt every plan. The config map has `ignore_changes = [data]` to prevent constant drift. This means changes to `ntfy_users` won't propagate automatically -- you need to taint the config map.
- **Prerequisite**: Headscale users must exist in the homelab project's tailnet-infra module before applying.
- **Image tags**: All images default to `:latest`. Override via `image_*` variables if you need to pin.
- **PVCs have `prevent_destroy`**: You cannot destroy PVCs through terraform without first removing the lifecycle block.
