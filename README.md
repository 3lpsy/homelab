# Readme

# TODO:
- delete cal record manually added to r53 once migrated
- No containerd, only podman and nomad
- TODO: Let vault run and make sure it doesn't restart (tailnet key may expire)
- Setup Nomad
	- Build vault on Nomad (local/not in registry)
	- Should be able to connect to TS
	- Need to get bootstrapped and get keys for provider
	- Start Vault
- Get Vault provider setup in TF
	- Seed vault with registry TLS
	- Seed vault with registry Creds
- Setup Registry
	- Build registry locally on nomad (local/not in registry)
	- Should be able to connect to TS
	- Should be able to connect to Vault (HS ACLs will need updating)
- Start Registry / Get Registry Setup
- Build any necessary images
- Deploy Images
- TLS
	- Only managed TLS is HS/Nomad/Vault
		- HS/Nomad require file manip for updating (or TF apply)
		- Vault can be rebuilt and replaced
	- All others should pull from vault

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
