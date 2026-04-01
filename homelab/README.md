# Homelab

Foundation deployment. Creates AWS infrastructure, provisions a Headscale control server, sets up the Tailscale mesh network and tailnet users, and deploys a Tailscale exit node. Everything downstream (cluster, vault, vault-conf, nextcloud, monitoring, monitoring-conf) depends on this deployment's state outputs.

## Architecture

Three servers connected via a Headscale-managed Tailscale mesh:

- **Headscale EC2** (Ubuntu) -- control plane for the tailnet. Runs Headscale with Nginx TLS termination. Hosts encrypted backups to S3.
- **K3s node** (Fedora, on-prem LAN) -- single-node Kubernetes cluster. Provisioned by the `cluster` deployment.
- **Exit node EC2** (Ubuntu) -- Tailscale exit node for routing traffic through AWS.

## Deployment flow

Modules execute roughly in this order based on `depends_on` chains:

```
1. ACME account registration
   └─ homelab-infra-tls

2. Headscale server (AWS)
   ├─ headscale-infra          VPC, EC2, EIP, S3 bucket, IAM
   ├─ headscale-infra-dns      Route53 zones + records
   ├─ headscale-infra-tls      Let's Encrypt cert (DNS challenge)
   ├─ headscale-provision-dep  apt packages, Headscale binary
   ├─ headscale-provision-tls  Deploy certs to server
   ├─ headscale-provision-nginx  Reverse proxy (443 → 8443)
   └─ headscale-provision-headscale  Config, systemd, API key, backups

3. Tailnet
   └─ tailnet-infra            Headscale users + pre-auth keys

4. Exit node
   └─ exit-node-0              EC2 + Tailscale with exit node flag
```

## Modules

### AWS / Headscale infrastructure

| Module | Source | Purpose |
|---|---|---|
| `homelab-infra-tls` | local | ACME account key (RSA 4096) for Let's Encrypt |
| `headscale-infra` | local | VPC, subnet, IGW, security group, EC2, EIP, S3 bucket, IAM role |
| `headscale-infra-dns` | local | Route53 zones for server domain and magic domain, NS delegation |
| `headscale-infra-tls` | template `infra-tls` | ACME cert for Headscale server |
| `headscale-provision-tls` | template `provision-tls` | SCP certs to /etc/letsencrypt/live/ |
| `headscale-provision-dep` | local | apt: nginx, curl, age, aws-cli, Headscale v0.25.1 binary |
| `headscale-provision-nginx` | template `provision-nginx` | Nginx reverse proxy (port 8443, HTTPS backend) |
| `headscale-provision-headscale` | local | Headscale config, ACLs, systemd, API key creation, encrypted S3 backups |

### Tailnet

| Module | Source | Purpose |
|---|---|---|
| `tailnet-infra` | local | Creates ~18 Headscale users + pre-auth keys for cluster node, exit node, TV |

### Exit node

| Module | Source | Purpose |
|---|---|---|
| `exit-node-0` | local | EC2 in Headscale VPC, Tailscale install with `--advertise-exit-node`, IP forwarding |

## Shared templates

Templates in `../templates/` are reused across this and other deployments:

- **`infra-tls`** -- ACME cert generation via Route53 DNS challenge.
- **`provision-tls`** -- SCP certs to a server, set permissions, SELinux relabel.
- **`provision-nginx`** -- Deploy Nginx reverse proxy config via SSH.

## Outputs

| Output | Consumed by |
|---|---|
| `acme_account_key_pem` | cluster, vault (TLS cert generation) |
| `tailnet_user_map` | vault, nextcloud, monitoring (Headscale pre-auth keys) |
| `headscale_server_fqdn` | cluster, vault, nextcloud, monitoring (Tailscale login server, provider endpoint) |
| `node_preauth_key` | cluster (tailnet join) |

## Tailnet users

The `tailnet_users` map defines ~18 Headscale users. Each maps a role key to a username (e.g., `vault_server_user → "vault-server"`). Downstream deployments reference these by key to create pre-auth keys for their services.

## Gotchas

- **Headscale API key bootstrap**: On first apply, `headscale_api_key` is empty. The headscale-provision-headscale module creates the key and writes it to `headscale_key_path`. You must then set `headscale_api_key` in `.env` and re-apply for the Headscale provider and tailnet-infra to work.
- **Headscale users have `prevent_destroy`** in tailnet-infra. Remove the lifecycle block before destroying.
- **Recursive nameservers** (Quad9 by default) are required for ACME DNS challenge validation because the magic domain resolves through Headscale's DNS.
