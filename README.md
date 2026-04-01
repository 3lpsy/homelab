# Readme

A home network that utilizes headscale in AWS and a single K3s node. Continuous work in progress and intended for personal use so you probably don't want to use this.

# Register Domains

Headscale requires two domains. The necessity of the second one depends on what services you want and whether you'll need TLS certs for nginx. Anyways, the first domain will be the headscale server domain. The second will be the magic DNS domains. The deployment will create the hosted zones so they probably shouldn't exist. If they do, just import them.

# Servers
- Headscale EC2
- K3s Server on LAN
- Exit Node EC2

# Service Overview
- Headscale / Tailnet (with Encrypted backup of State to S3)
- Nextcloud + Collabora
- Immich
- PiHole (Configured as advertised Headscale DNS server)
- Radicale (CalDAV/CardDav)
- Registry (Docker Registry v2)
- Grafana / Prometheus / Node Exporter / kube-state-metrics / Ntfy

## Create SSH Key

This key pair will be used for a few things. First, its public key is used to do client side encryption of the tfstate before backing up to S3. Second, it's private key is used to provision headscale and other services.

```
ssh-keygen -f data/ssh.pem
```

## Deploy

```
# initial infrastructure
./terraform.sh homelab init
./terraform.sh homelab apply

# provision k3s node
./terraform.sh cluster init
./terraform.sh cluster apply

# create vault in k3s
./terraform.sh vault init
./terraform.sh vault apply

# after unsealing vault, importing dummy key
$ ./terraform.sh vault-conf import kubernetes_secret.vault_unseal_keys vault/vault-unseal-keys

./terraform.sh vault-conf init
./terraform.sh vault-conf apply

# deploy all the services (nextcloud, collabora, registry, pihole, etc)
./terraform.sh nextcloud init
./terraform.sh nextcloud apply

# deploy monitoring (grafana + prometheus + ntfy)
./terraform.sh monitoring init
./terraform.sh monitoring apply

# configure grafana dashboards and alerts
./terraform.sh monitoring-conf init
./terraform.sh monitoring-conf apply
```

## Notes
- Need to use recursive name servers for ACME magic domains to avoid local DNS searching.
- Initial k3s provisioning done over local IP instead of tailscale to onboard it and then done over tailscale
