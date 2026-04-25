# Homelab

Foundation deployment. Creates all AWS infrastructure, provisions the
Headscale control server, joins it to its own tailnet, and defines the
tailnet users. Every downstream deployment (cluster, vault, vault-conf,
nextcloud, monitoring, monitoring-conf) reads this deployment's state
via `terraform_remote_state`.

## Architecture

Two live servers, both connected via Tailscale:

- **Headscale EC2** (Ubuntu). Headscale control plane, served behind
  Nginx TLS. Runs encrypted state backups to S3. Also joined to its
  own tailnet as `headscale-host` so SSH and the OTel host agent
  (installed by the `monitoring` deployment) can reach it by tailnet
  name.
- **K3s node** (Fedora, LAN). Single-node Kubernetes cluster.
  Provisioned by the `cluster` deployment, not here.

Exit-node egress has moved into the cluster and no longer runs on
AWS. See `nextcloud/README.md` for the in-cluster WireGuard proxies.

## Deployment flow

Modules execute roughly in this order through `depends_on` chains:

```
1. ACME account
   homelab-infra-tls

2. Headscale server (AWS)
   headscale-infra             VPC, subnet, IGW, SG, EC2, EIP, S3 bucket, IAM
   headscale-infra-dns         Route53 zones and records
   headscale-infra-tls         Let's Encrypt cert (DNS-01)
   headscale-provision-tls     SCP certs to the server
   headscale-provision-dep     apt deps plus the Headscale binary
   headscale-provision-nginx   Nginx reverse proxy (443 -> 8443)
   headscale-provision-headscale  Config, ACLs, systemd, API key, backups

3. Tailnet
   tailnet-infra               Headscale users + pre-auth keys

4. Join the server to its own tailnet
   headscale-provision-tailscale  Installs Tailscale on the Headscale EC2
                                  using the headscale-host pre-auth key
```

## Modules

### AWS + Headscale

| Module | Source | Purpose |
|---|---|---|
| `homelab-infra-tls` | local | ACME account key (RSA 4096) for Let's Encrypt |
| `headscale-infra` | local | VPC, subnet, IGW, security group, EC2, EIP, S3 bucket, IAM |
| `headscale-infra-dns` | local | Route53 zones for server domain and magic domain, NS delegation |
| `headscale-infra-tls` | `templates/infra-tls` | ACME cert for the Headscale server FQDN |
| `headscale-provision-tls` | `templates/provision-tls` | SCP certs to `/etc/letsencrypt/live/` |
| `headscale-provision-dep` | local | apt: nginx, curl, age, aws-cli, Headscale binary |
| `headscale-provision-nginx` | `templates/provision-nginx` | Nginx reverse proxy (`443 -> 8443`) |
| `headscale-provision-headscale` | local | Headscale config, ACLs, systemd unit, API key, encrypted S3 backups |

### Tailnet

| Module | Source | Purpose |
|---|---|---|
| `tailnet-infra` | local | Headscale users plus pre-auth keys for the K3s node, exit-node pods, app services, and the headscale host itself |

### Server self-join

| Module | Source | Purpose |
|---|---|---|
| `headscale-provision-tailscale` | local | Installs Tailscale on the Headscale EC2 and joins it to the tailnet as `headscale-host` |

## Shared templates

Templates in `../templates/` are reused across deployments:

- **`infra-tls`**: ACME cert issuance via the Route53 DNS challenge.
- **`provision-tls`**: SCP certs to a remote host, set permissions,
  SELinux relabel.
- **`provision-nginx`**: Deploy an Nginx reverse-proxy config via SSH.

## Outputs

| Output | Consumed by |
|---|---|
| `acme_account_key_pem` | cluster, vault, nextcloud, monitoring (per-deployment Let's Encrypt certs) |
| `tailnet_user_map` | vault, nextcloud, monitoring (look up Headscale pre-auth keys by role key) |
| `headscale_server_fqdn` | cluster, vault, nextcloud, monitoring (Tailscale login server, Headscale provider endpoint) |
| `node_preauth_key` | cluster (initial tailnet join) |
| `headscale_ec2_public_ip`, `headscale_ec2_ssh_user`, `headscale_ec2_tailnet_hostname` | monitoring (SSH-based OTel host-agent install) |

## Tailnet users

The `tailnet_users` variable maps a role key to a Headscale username.
Every downstream service that needs a tailnet identity looks up its
pre-auth key through `tailnet_user_map[role_key]`. Current roles:
`personal_user`, `personal_laptop_user`,
`nomad_server_user` (legacy name for the K3s node), `mobile_user`, `registry_server_user`, `grafana_server_user`,
`prometheus_user`, `openwrt_user`, `calendar_server_user`,
`tablet_user`, `deck_user`, `devbox_user`, `exit_node_user`,
`tv_user`, `vault_server_user`, `nextcloud_server_user`,
`collabora_server_user`, `pihole_server_user`, `ntfy_server_user`,
`ollama_server_user`, `litellm_server_user`,
`thunderbolt_server_user`, `mcp_user`, `builder_user`,
`searxng_server_user`, `log_server_user`, `headscale_host_user`,
`homeassist_server_user`, `frigate_server_user`,
`pod_provisioner_user` (used by the OpenObserve bootstrap Job to
reach Vault over the tailnet).

## Gotchas

- **Headscale API key bootstrap**. On the first apply,
  `headscale_api_key` is empty. `headscale-provision-headscale`
  creates the key and writes it to `headscale_key_path` on disk. Set
  `headscale_api_key` in `.env` from that file, then re-apply so the
  Headscale provider and `tailnet-infra` can run.
- **Headscale users have `prevent_destroy`** in `tailnet-infra`.
  Remove the lifecycle block before destroying.
- **Recursive nameservers** (Quad9 by default) are required for ACME
  DNS-01 validation because the magic domain resolves through
  Headscale's own DNS.
- **Legacy module variable names** inside `tailnet-infra` still use
  `nomad_*` for what is now the K3s node (e.g.
  `nomad_server_preauth_key`). The output alias `node_preauth_key`
  hides that from downstream deployments.
- **Encrypted state backups** are produced by
  `headscale-provision-headscale` using the public key at
  `data/ssh.pem` as the age recipient.
