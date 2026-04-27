# Homelab

Personal infrastructure as code for a hybrid AWS + on-prem homelab. The
AWS side runs a Headscale control plane. The on-prem side runs a
single-node K3s cluster that hosts every user-facing service and all
shared infra. Outbound egress goes through in-cluster WireGuard
proxies. Everything is wired together over Tailscale with Let's
Encrypt TLS.

Continuous work in progress. Not intended for anyone else's use.

## Stack

- Terraform, modular per deployment
- K3s (single node, Fedora host)
- AWS (EC2 for Headscale, VPC, Route53, S3 for encrypted state backup)
- Headscale / Tailscale mesh
- HashiCorp Vault with the Secrets Store CSI Driver and Vault CSI Provider
- Let's Encrypt via ACME DNS-01
- Prometheus, Alertmanager, Grafana, Ntfy, OTel Collector, OpenObserve
- Rootless BuildKit Jobs for in-cluster image builds, pushed to an
  in-cluster Registry

## Layout

Each deployment is a self-contained Terraform module with its own
state file. `./terraform.sh` is a thin wrapper that handles
per-deployment state paths, age-encrypted S3 backup of state, and a
`changes` helper that plans every deployment sequentially.

| Deployment | Purpose |
|---|---|
| `homelab/` | AWS foundation: VPC, Headscale EC2, Route53 zones, ACME account, tailnet users. |
| `cluster/` | K3s node provisioning: tailnet join, TLS certs, K3s install, host hardening. |
| `vault/` | Vault StatefulSet on K3s with an auto-unseal sidecar and the Secrets Store CSI stack. |
| `vault-conf/` | Vault configuration: K8s auth, KV engine, unseal key secret. |
| `nextcloud/` | All user-facing services (incl. Home Assistant + Frigate) plus shared infra (Postgres, Redis, Builder, exit-node proxies, MCP servers). |
| `monitoring/` | Prometheus, Alertmanager, Grafana, Ntfy, OpenObserve, OTel Collector, node-exporter, kube-state-metrics, Reloader. |
| `monitoring-conf/` | Grafana dashboards applied via the Grafana provider. |

Service-level details live in each deployment's own `README.md`.

## Deployment ordering

State outputs flow strictly downstream through `terraform_remote_state`,
so the first apply has to run in order. Later applies can target a
single deployment.

```
homelab -> cluster -> vault -> vault-conf -> nextcloud -> monitoring -> monitoring-conf
```

First run requires two manual interruptions:

1. **Headscale API key bootstrap** inside the `homelab` deployment.
   The first `homelab apply` creates the Headscale server, but the
   API key variable is empty. The provisioning module writes the
   generated key to `headscale_key_path` on disk. Set
   `headscale_api_key` in `.env` from that file, then re-apply
   `homelab` so the Headscale provider and `tailnet-infra` can run.
2. **Vault unseal bootstrap** between `vault apply` and `vault-conf apply`.
   Vault comes up sealed with a dummy unseal key. Run
   `vault operator init`, unseal manually, then import the secret
   into `vault-conf` state before applying it:

   ```
   ./terraform.sh vault-conf import kubernetes_secret.vault_unseal_keys vault/vault-unseal-keys
   ./terraform.sh vault-conf apply
   ```

## Prerequisites

- Two domains registered: one for the Headscale server, one for the
  Tailscale magic DNS. Route53 hosted zones are created by the
  `homelab` deployment. If the zones already exist, import them
  before applying.
- An SSH key pair at `data/ssh.pem`. The public key is also used as
  the age recipient for encrypting tfstate backups. The private key
  is used for SSH into Headscale and the K3s node:

  ```
  ssh-keygen -f data/ssh.pem
  ```

- A `.env` file at the repo root. See `.env.example` for required
  variables.

## Common commands

```
./terraform.sh <deployment> init
./terraform.sh <deployment> apply
./terraform.sh <deployment> plan
./terraform.sh <deployment> destroy
./terraform.sh <deployment> import <resource> <id>
./terraform.sh all plan
./terraform.sh changes            # plan every deployment, show only diffs
./terraform.sh encrypt            # age-encrypt every local tfstate
./terraform.sh tf-backup          # encrypt, then upload encrypted blobs to S3
```

## Service inventory

User-facing services. All are fronted by Nginx (TLS termination) and
exposed over Tailscale with Let's Encrypt certs:

- Nextcloud and Collabora
- Immich
- PiHole, advertised as the Headscale DNS server
- Radicale (CalDAV / CardDAV)
- Registry (Docker Registry v2), consumed by in-cluster image builds
- SearXNG, with a ranker daemon that reprobes and reorders engines on
  a rolling schedule
- LiteLLM, proxying Bedrock and other providers with Postgres-backed
  spend tracking
- Thunderbolt: Keycloak OIDC, single-node MongoDB replica set,
  Postgres, PowerSync, a Node.js backend, and a static Nginx frontend
- Home Assistant, with a co-located Mosquitto MQTT broker and a
  Zigbee2MQTT pod (USB coordinator passed through to the K3s node)
- Frigate, NVR with VAAPI hwaccel decode (AMD render node passthrough)
- Grafana
- Ntfy
- OpenObserve (logs and traces)

MCP servers. All sandboxed per-API-key and exposed through a single
shared Nginx gateway in the `mcp` namespace:

- `mcp-filesystem`, `mcp-memory`, `mcp-prometheus`, `mcp-k8s`,
  `mcp-k8s-auth-gate`, `mcp-litellm`, `mcp-searxng`, `mcp-time`

Shared infrastructure in the `nextcloud` deployment:

- Postgres (used by Nextcloud and Radicale)
- Redis (Nextcloud session and cache state)
- `builder` namespace: rootless BuildKit Jobs that build every custom
  image and push to the in-cluster Registry
- `exitnode` namespace: one Deployment per WireGuard config, each
  wrapping a WireGuard client and a tinyproxy sidecar so in-cluster
  workloads can egress through ProtonVPN

## Operational notes

- Initial K3s provisioning uses the node's LAN IP. Once joined to the
  tailnet, subsequent actions go over Tailscale.
- Recursive nameservers (Quad9 by default) are required for ACME
  DNS-01 validation because the magic domain is served by Headscale
  itself.
- State files live at
  `$HOME/Playground/private/envs/homelab/<deployment>/terraform.tfstate`.
  `./terraform.sh tf-backup` age-encrypts each state using
  `data/ssh.pem` as the recipient and uploads the encrypted blobs to
  S3. The decrypt, pull, and restore counterparts are commented out
  in `terraform.sh` on purpose.
- PVCs have `prevent_destroy = true`. Remove the lifecycle block
  before running `destroy`.
- Headscale users created by `tailnet-infra` also have
  `prevent_destroy`.
- Ntfy user config uses `bcrypt()` with `ignore_changes = [data]`, so
  user list changes don't propagate on a normal apply. Taint the
  config map to force an update.
- Nextcloud's container image is built in-cluster and pulled from the
  in-cluster Registry, so the Registry must be reachable before the
  Nextcloud Deployment can start.
- Thunderbolt's MongoDB runs as a single-node replica set so the
  backend can use native transactions. Standalone Mongo will not work.
- Custom-image builds are keyed off their Dockerfile hash, so
  unchanged sources do not re-trigger BuildKit.
