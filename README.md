# Readme

# TODO:
- No ansible, just terraform
  - Make sure /etc/headscale exists (correct perms)
  - Write headscale config
  - Write headscale service file
  - Need to re/start services
  - Need to configure log rotation

  - Need to restore from backup if exists (regular backups done by nomad)
  - Need to enable auto update

  - Next, move on to management of headscale via terraform.

# Gather Tools

Install `terraform`

# Register Domains
Headscale requires two domains. The necessity of the second one depends on what services you want and whether you'll need TLS certs for nginx. Anyways, the first domain will be the headscale server domain. The second will be the magic DNS domains. The deployment will create the hosted zones so they probably shouldn't exist. If they do, just import them.

## Create SSH Key
This key encrypts anything sent to S3 and is passed around

```
openssl rand 64 | sha256sum | cut -d ' ' -f 1 > data/tfstate.key
```

## Create SSH Key

```
ssh-keygen -f data/ssh.pem
```

## Deploy
```
./terraform.sh homelab init
./terraform.sh homelab deploy
```
