# Nextcloud Deployment

Terraform deployment for every user-facing service on the cluster plus
the cross-cutting shared infrastructure. The name is historical; this
deployment owns far more than Nextcloud.

## Namespaces

One namespace per trust boundary, each with its own service account,
Vault role, and TLS cert where applicable.

| Namespace | Workloads |
|---|---|
| `nextcloud` | Nextcloud, Collabora, Immich (app, ML, Postgres, Redis), shared Postgres, shared Redis |
| `pihole` | PiHole |
| `registry` | Docker Registry v2 |
| `radicale` | Radicale |
| `searxng` | SearXNG (with embedded Valkey sidecar), searxng-ranker daemon |
| `litellm` | LiteLLM, litellm-postgres |
| `thunderbolt` | Keycloak, Postgres, Mongo, PowerSync, backend, frontend |
| `homeassist` | Home Assistant, Mosquitto MQTT broker, Zigbee2MQTT |
| `frigate` | Frigate NVR |
| `mcp` | `mcp-shared` nginx gateway plus `mcp-filesystem`, `mcp-memory`, `mcp-prometheus`, `mcp-k8s` (with auth-gate sidecar), `mcp-litellm`, `mcp-searxng`, `mcp-time` |
| `exitnode` | One Deployment per WireGuard config, each a WireGuard client + tinyproxy sidecar |
| `builder` | Rootless BuildKit Jobs that build custom images and push to the Registry |

## User-facing services

All externally-exposed pods follow the same pattern: main app container,
Nginx sidecar for TLS termination, Tailscale sidecar for mesh access.
Secrets come from Vault through the Secrets Store CSI Driver.

| Service | Purpose | Notes |
|---|---|---|
| Nextcloud | File sync and collaboration | Custom image built in-cluster; pulled from the in-cluster Registry |
| Collabora | Online document editing | Exposed as a Nextcloud plugin; Nextcloud talks to it over HTTPS via the `collabora-internal` ClusterIP and `host_aliases` trick |
| Immich | Photos and video | Separate Postgres (pgvecto.rs) and Redis; the ML pod runs internal-only on port 3003 |
| PiHole | DNS ad-blocking | Advertised as the Headscale DNS server |
| Radicale | CalDAV / CardDAV | Auth htpasswd generated at pod startup via an init container |
| Registry | Docker Registry v2 | Holds every in-cluster image build |
| SearXNG | Meta-search | Embedded Valkey sidecar for per-request cache; ranker daemon rewrites engine config on a rolling schedule |
| LiteLLM | LLM proxy | Backed by its own Postgres for spend tracking; keys managed via LiteLLM's admin UI |
| Thunderbolt | Custom app stack | Keycloak OIDC (Postgres-backed), single-node Mongo replica set, PowerSync, Node.js backend on 8000, static Nginx frontend |
| Home Assistant | Home automation | Pod-network HA Container; init containers seed `configuration.yaml`, the admin user (via `hass --script auth`), and `.storage/onboarding` + `core.config` to skip the web wizard. ESPHome BT proxies live on the LAN, not here |
| Mosquitto | MQTT broker for HA | Co-located in the `homeassist` namespace; init container builds `mosquitto_passwd` from Vault-managed `ha` and `z2m` passwords on every pod start |
| Zigbee2MQTT | Zigbee bridge | Same namespace as HA; reuses the HA Tailscale auth secret. USB coordinator passthrough is gated on `homeassist_z2m_usb_device_path` — empty until the dongle is wired in. Nginx sidecar adds htpasswd auth (Z2M has no native UI auth) |
| Frigate | NVR / camera review | AMD VAAPI hwaccel decode via `/dev/dri` host_path; `/dev/shm` upsized to 512Mi for ffmpeg frame buffers; init container seeds Frigate's auth DB with the Vault-managed admin password (PBKDF2). Day-1 config has no cameras |
| Grafana, Ntfy, OpenObserve | Monitoring surfaces | Deployed in the `monitoring` deployment, not here |

## MCP gateway

Every MCP server sits behind a single `mcp-shared` Nginx pod in the
`mcp` namespace. `mcp-shared` handles TLS (Let's Encrypt, Tailscale),
CORS, and path-prefix routing (`/mcp-<name>/` -> the backend's
ClusterIP). Backend auth is per-API-key, enforced by the backend's
own middleware (bearer header, with `?api_key=` query fallback).

Notes on individual MCPs:

- `mcp-filesystem`, `mcp-memory`: sandbox per hashed API key on their
  own PVCs. Strict tenant + session isolation, input validation, and
  quotas enforced in-process.
- `mcp-k8s`: upstream server plus a local `auth-gate` sidecar. The
  pod exposes only the auth-gate (`:8000`) externally; the upstream
  listens on `:8080` inside the pod so no unauthenticated path is
  reachable.
- `mcp-searxng`, `mcp-litellm`: keep their own Tailscale sidecars so
  they can reach upstreams on their tailnet FQDNs (in-cluster DNS
  would TLS-fail on those names).

## Shared infrastructure

- **Postgres** (shared). Backs Nextcloud and Radicale. Separate from
  Immich's and LiteLLM's own Postgres instances.
- **Redis** (shared). Nextcloud session and cache state. Immich has
  its own Valkey-based cache.
- **Builder namespace**. Rootless BuildKit in the `builder` namespace
  runs one-shot Jobs keyed off each Dockerfile's hash. Images push to
  the in-cluster Registry with credentials from `builder-secrets.tf`.
- **Exit-node proxies**. One Deployment per WireGuard config in the
  `exitnode` namespace. Each pod runs WireGuard (tunnel to ProtonVPN)
  plus tinyproxy (HTTP[S] CONNECT proxy). Downstream services that
  need region-specific egress point at the matching
  `exitnode-<name>.exitnode.svc.cluster.local` service. `tinyproxy`
  is a custom image, rebuilt via `exitnode-tinyproxy-jobs.tf`.
- **OTel Collector**. An in-cluster collector (configured in
  `otel-collector-jobs.tf`, image in `data/images/otel-collector/`)
  scrapes app telemetry and forwards to the monitoring deployment.

## File conventions

Inside this deployment, each service is split across files by concern:

- `<service>.tf` -- Deployment and Service
- `<service>-secrets.tf` -- Namespace (if owned), service account, RBAC,
  Tailscale pre-auth key, TLS cert, Vault policy / role / secrets, CSI
  SecretProviderClass
- `<service>-config.tf` -- ConfigMaps (app config, nginx config via
  `templatefile()`)
- `<service>-pvc.tf` -- PersistentVolumeClaims (`prevent_destroy`
  lifecycle block)
- `<service>-jobs.tf` -- BuildKit image builds, DB schema init, and any
  post-deploy bootstrap. Not universal.

One cross-cutting file does not belong to a single service:

- `builder-secrets.tf` -- shared `builder` namespace wiring (Tailscale
  pre-auth key, registry pull-secret) consumed by every BuildKit job.

Nginx templates live in `../data/nginx/<service>.nginx.conf.tpl` and
are rendered via `templatefile()`. The wait-for-secrets init
container script is at `../data/scripts/wait-for-secrets.sh.tpl`.

## Gotchas

- **PVCs have `prevent_destroy`**. Nextcloud, Immich, Radicale, and
  Registry data are protected. Remove the lifecycle block before any
  `destroy`.
- **Registry htpasswd** uses `bcrypt()` with
  `ignore_changes = [data_json]` on the Vault secret. Bcrypt produces
  a new hash each plan, so updates never apply automatically. Taint
  `vault_kv_secret_v2.registry_htpasswd` to force an update.
- **Jobs use `timestamp()` in names** with
  `ignore_changes = [metadata[0].name]`, so every `apply` creates a
  fresh Job. Completed Jobs accumulate until garbage-collected.
- **Nextcloud image comes from the in-cluster Registry**
  (`registry.<domain>/nextcloud:latest`). The BuildKit Job must have
  succeeded and pushed before the Nextcloud Deployment can start.
- **Collabora <-> Nextcloud HTTPS loop** relies on the
  `collabora-internal` ClusterIP service and `host_aliases` on the
  Nextcloud pod. Do not remove either.
- **Radicale auth** is generated at pod startup by an init container
  that runs `pip install passlib` and writes an htpasswd file. First
  boot requires outbound internet access.
- **PiHole's Tailscale sidecar** has extra capabilities
  (`NET_BIND_SERVICE`, `NET_RAW`, `SYS_NICE`, `CHOWN`) beyond the
  usual `NET_ADMIN` so it can bind DNS ports.
- **Thunderbolt Mongo is a single-node replica set**, not standalone.
  The backend relies on native transactions, which require replset.
- **Exit-node DNS** is stripped from the WireGuard config at render
  time (`exitnode.tf` locals) so pods keep using in-cluster DNS.
- **`mcp-shared` is the only externally-reachable MCP service**. The
  other MCP deployments only have ClusterIP services; they rely on
  `mcp-shared` for TLS and auth surface.

## Deployment order

Depends on three prior deployments through `terraform_remote_state`:

1. `homelab` -- Headscale FQDN, ACME account key, tailnet user map.
2. `vault` -- Vault endpoint and CSI driver.
3. `vault-conf` -- Vault KV mount path, Kubernetes auth backend.
