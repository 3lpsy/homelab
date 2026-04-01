# Homelab

Foundation deployment. Creates AWS infrastructure, provisions a Headscale control server, sets up the Tailscale mesh network, provisions the K3s node, and deploys a Tailscale exit node. Everything downstream (vault, vault-conf, nextcloud, monitoring, monitoring-conf) depends on this deployment's state outputs.

**Note**: The K3s node was originally a Nomad node. Module names still reflect this (`nomad-*`, `tailnet-provision-nomad`). A rename is planned.

## Architecture

Three servers connected via a Headscale-managed Tailscale mesh:

- **Headscale EC2** (Ubuntu) -- control plane for the tailnet. Runs Headscale with Nginx TLS termination. Hosts encrypted backups to S3.
- **K3s node** (Fedora, on-prem LAN) -- single-node Kubernetes cluster. Joined to the tailnet via Tailscale. All workloads run here.
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

4. K3s node (named "nomad" in code)
   ├─ tailnet-provision-nomad  Join tailnet, firewalld trust
   ├─ nomad-infra-tls          Let's Encrypt cert for K3s host
   ├─ nomad-provision-tls      Deploy certs to K3s host
   ├─ nomad-provision-dep      dnf packages (git, nginx, etc.)
   └─ nomad-provision-server   K3s install, firewalld, DNS config

5. Exit node
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
| `tailnet-infra` | local | Creates ~18 Headscale users + pre-auth keys for K3s node, exit node, TV |
| `tailnet-provision-nomad` | local | Installs Tailscale on K3s host, joins tailnet, trusts tailscale0 in firewalld |

### K3s node provisioning

| Module | Source | Purpose |
|---|---|---|
| `nomad-infra-tls` | template `infra-tls` | ACME cert for K3s host's magic domain name |
| `nomad-provision-tls` | template `provision-tls` | SCP certs to K3s host |
| `nomad-provision-dep` | local | dnf: git, nginx, neovim, wget, yq |
| `nomad-provision-server` | local | K3s install (wireguard-native flannel), firewalld ports, systemd-resolved config, registry mirror config, scoped DNS for tailnet |

### Exit node

| Module | Source | Purpose |
|---|---|---|
| `exit-node-0` | local | EC2 in Headscale VPC, Tailscale install with `--advertise-exit-node`, IP forwarding |

### Unused

| Module | Source | Purpose |
|---|---|---|
| `service-vault` | local | Legacy Nomad job spec for Vault. Not referenced in main.tf. Dead code. |

## Shared templates

Templates in `../templates/` are reused across this and other deployments:

- **`infra-tls`** -- ACME cert generation via Route53 DNS challenge.
- **`provision-tls`** -- SCP certs to a server, set permissions, SELinux relabel.
- **`provision-nginx`** -- Deploy Nginx reverse proxy config via SSH.

## Outputs

| Output | Consumed by |
|---|---|
| `acme_account_key_pem` | vault (TLS cert generation) |
| `tailnet_user_map` | vault, nextcloud, monitoring (Headscale pre-auth keys) |
| `headscale_server_fqdn` | vault, nextcloud, monitoring (Tailscale login server, provider endpoint) |

## Tailnet users

The `tailnet_users` map defines ~18 Headscale users. Each maps a role key to a username (e.g., `vault_server_user → "vault-server"`). Downstream deployments reference these by key to create pre-auth keys for their services.

## Gotchas

- **Initial provisioning uses the LAN IP** (`nomad_server_ip`). After tailnet-provision-nomad joins the mesh, subsequent modules connect via the Tailscale hostname (`nomad-infra-tls.certificate_domain`).
- **Headscale API key bootstrap**: On first apply, `headscale_api_key` is empty. The headscale-provision-headscale module creates the key and writes it to `headscale_key_path`. You must then set `headscale_api_key` in `.env` and re-apply for the Headscale provider and tailnet-infra to work.
- **K3s node is Fedora** -- uses dnf, firewalld, systemd-resolved. Headscale EC2 and exit node are Ubuntu.
- **Headscale users have `prevent_destroy`** in tailnet-infra. Remove the lifecycle block before destroying.
- **Recursive nameservers** (Quad9 by default) are required for ACME DNS challenge validation because the magic domain resolves through Headscale's DNS.
- **Nomad naming** -- modules named `nomad-*` and `tailnet-provision-nomad` actually provision K3s infrastructure. Rename planned.
- **`service-vault` module is dead code** -- legacy Nomad job spec, not referenced anywhere.
