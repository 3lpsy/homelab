# Readme

A home network that utilizes headscale in AWS and a single K3s node. Continuous work in progress.

# Register Domains
Headscale requires two domains. The necessity of the second one depends on what services you want and whether you'll need TLS certs for nginx. Anyways, the first domain will be the headscale server domain. The second will be the magic DNS domains. The deployment will create the hosted zones so they probably shouldn't exist. If they do, just import them.

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

# create vault in k3s
./terraform.sh vault init
./terraform.sh vault apply

# after unsealing vault
./terraform.sh vault-conf init
./terraform.sh vault-conf apply

# deploy nextcloud + collabora
./terraform.sh nextcloud init
./terraform.sh nextcloud apply
```

## Notes
- Need to use recursive name servers for ACME magic domains to avoid local DNS searching.
- Initial k3s provisioning done over local IP instead of tailscale to onboard it and then done over tailscale
- Double check nameservers in hosted zone created match that from "Registered Domains" (Registrar Nameservers)
