# Monitoring

Deploys the observability stack into the `monitoring` namespace on
K3s: metrics, logs, dashboards, alerting, and host-level telemetry for
the Headscale EC2.

## Services

- **Prometheus** -- scrapes node-exporter, kube-state-metrics,
  kubelet / cAdvisor, the in-cluster OTel Collector, and an OpenWrt
  target over Tailscale. Evaluates alert rules and forwards firing
  alerts to Alertmanager. Cluster-internal only (ClusterIP), exposed
  externally only through Grafana. Rules in
  `../data/prometheus/alert-rules.yml.tpl`.
- **Alertmanager** -- sidecar in the Prometheus pod. Routes alerts to
  the ntfy-bridge sidecar. Config template in
  `../data/prometheus/alertmanager.yml.tpl`.
- **ntfy-bridge** -- Python sidecar in the Prometheus pod. Receives
  Alertmanager webhooks, reformats them into human-readable push
  notifications with title / priority / tags, applies the overnight
  mute window (00:00-09:00 CST), and forwards to Ntfy over Tailscale.
  Script at `../data/scripts/ntfy-bridge.py`.
- **Grafana** -- exposed over Tailscale with Nginx TLS termination.
  Admin password and TLS certs pulled from Vault via the CSI driver.
  Dashboards are provisioned by the `monitoring-conf` deployment, not
  here.
- **Ntfy** -- push notification server. Receives formatted alerts
  from ntfy-bridge over Tailscale and is also exposed externally over
  Tailscale with Nginx TLS. User list managed via Vault.
- **Node Exporter** -- DaemonSet on host network, no sidecar.
- **kube-state-metrics** -- cluster-internal, scraped by Prometheus.
- **OTel Collector** -- DaemonSet that receives OTLP from the
  application namespaces' collectors and forwards metrics to
  Prometheus and logs to OpenObserve. Config template in
  `../data/otel/collector-config.yaml.tpl`.
- **OpenObserve** -- log and trace store. Receives forwarded data
  from the OTel Collector. Exposed over Tailscale with Nginx TLS.
- **Reloader** -- watches Secrets and ConfigMaps and triggers rolling
  restarts on dependent Deployments when they change, so rotated TLS
  certs and secrets propagate without manual intervention.
- **Headscale host telemetry** -- `headscale-host-otel.tf` provisions
  an OTel Collector agent on the Headscale EC2 itself via
  `null_resource` over SSH. Config template in
  `../data/otel/headscale-collector-config.yaml.tpl`.

## Alert and telemetry flow

```
cluster:
  node-exporter, kube-state-metrics, app pods
    -> Prometheus
       -> Alertmanager (sidecar)
          -> ntfy-bridge (sidecar)
             -> Ntfy (over Tailscale)

app pods -> per-namespace OTel Collector -> monitoring OTel Collector
                                              -> Prometheus (metrics)
                                              -> OpenObserve (logs / traces)

Headscale EC2 -> OTel Collector agent (installed over SSH)
              -> monitoring OTel Collector (over Tailscale)
```

## File layout

Each Kubernetes-managed service is split across up to four files by
concern:

| Suffix | Contents |
|---|---|
| `<service>.tf` | Deployment / DaemonSet and Service |
| `<service>-secrets.tf` | Service account, RBAC, Headscale pre-auth key, TLS certs, Vault secrets / policy / role, CSI SecretProviderClass |
| `<service>-config.tf` | ConfigMaps (app config, nginx config) |
| `<service>-pvc.tf` | PersistentVolumeClaim |

`node-exporter`, `kube-state-metrics`, and `reloader` are small enough
to be single-file. `headscale-host-otel.tf` stands alone because it
runs against the Headscale EC2, not the cluster.

## Deployment pattern

Grafana, Ntfy, and OpenObserve follow the same pod structure:

1. Init containers (`wait-for-secrets`, fix-permissions)
2. Main application container
3. Nginx sidecar for TLS termination
4. Tailscale sidecar for mesh networking

Prometheus skips Nginx (cluster-internal only) but keeps the Tailscale
sidecar so its API remains reachable for ad-hoc probes. Alertmanager
and ntfy-bridge run as additional sidecars in the Prometheus pod and
share its Tailscale interface.

## Gotchas

- **Ntfy bcrypt config**: the server config uses `bcrypt()`, which
  re-salts on every plan. The ConfigMap has `ignore_changes = [data]`
  to prevent drift noise. Change `ntfy_users`? Taint the ConfigMap.
- **Prerequisite Headscale users**: the required tailnet users
  (grafana, ntfy, openobserve, prometheus, etc.) must exist in the
  `homelab` project's `tailnet-infra` module before this deployment
  can apply.
- **Image tags default to `:latest`**. Override via `image_*`
  variables if pinning is needed.
- **PVCs have `prevent_destroy`**. Remove the lifecycle block before
  running `destroy`.
- **Reloader vs `ignore_changes`**: Reloader only rolls Deployments
  whose annotations or pod templates reference the changed object.
  Resources using `ignore_changes` on config data (Ntfy bcrypt) are
  intentionally not auto-rolled; taint the ConfigMap to force the
  rollout.
- **Headscale OTel agent runs over SSH** via `null_resource`. If the
  EC2 is reprovisioned, re-run `monitoring apply` so the install and
  config steps rerun.
