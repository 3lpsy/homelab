# Readme

# TODO:
- No ansible, just terraform
  - Manually install kata, comes with ubuntu rootfs
  - Won't work, podman not supported
    - Potential setup: Nomad => Podman => Kata => Firecracker
  - nerdctl could be useful
    - Nerdctl => buildkit => containerd to get images
    - Nomad => ctr/containerd to manage images


# Gather Tools

Install `terraform` and `age` (or `age` complaint implementation)

# Register Domains
Headscale requires two domains. The necessity of the second one depends on what services you want and whether you'll need TLS certs for nginx. Anyways, the first domain will be the headscale server domain. The second will be the magic DNS domains. The deployment will create the hosted zones so they probably shouldn't exist. If they do, just import them.

## Create SSH Key

This key pair will be used for a few things. First, its public key is used to do client side encryption of the tfstate before backing up to S3. Second, it's private key is used to provision headscale and other services.

```
ssh-keygen -f data/ssh.pem
```

## Deploy
```
./terraform.sh homelab init
./terraform.sh homelab deploy
```

## Notes
- Need to use recursive name servers for ACME magic domains to avoid local DNS searching.
- Initial nomad provisioning done over local IP instead of tailscale to onboard it and then done over tailscale
- Double check nameservers in hosted zone created match that from "Registered Domains" (Registrar Nameservers)
