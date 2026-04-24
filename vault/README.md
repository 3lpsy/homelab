# Vault

Deploys HashiCorp Vault as a StatefulSet on K3s with file-backed
storage. Exposed externally over Tailscale with Nginx TLS; in-cluster
access is plaintext on port 8200.

## Architecture

- **Internal listener** (8200). Plaintext, ClusterIP service, used by
  the CSI driver and in-cluster consumers.
- **External listener** (8201). TLS via Let's Encrypt, reachable only
  over Tailscale. Nginx sidecar terminates TLS. Tailscale sidecar
  provides mesh access.
- **Auto-unseal sidecar**. Busybox loop that polls `/v1/sys/health`
  and unseals when sealed. Requires a valid unseal key in the
  `vault-unseal-keys` secret, which is populated by the `vault-conf`
  deployment after the manual bootstrap.
- **Secrets Store CSI Driver + Vault CSI Provider**. Helm-managed in
  `kube-system` and `vault-csi` respectively. Allows pods in any
  namespace to mount Vault KV secrets as files.

## File layout

| File | Contents |
|---|---|
| `main.tf` | Providers and the `vault` namespace |
| `vault.tf` | StatefulSet and Service |
| `vault-secrets.tf` | Service account, RBAC, Headscale pre-auth key, TLS certs, Tailscale auth, unseal-key secret, network policy |
| `vault-config.tf` | ConfigMaps (`vault.hcl`, auto-unseal script) |
| `vault-pvc.tf` | PersistentVolumeClaim (`prevent_destroy`) |
| `csi.tf` | Helm releases: Secrets Store CSI Driver, Vault CSI Provider |
| `dns.tf` | CoreDNS override so in-cluster lookups of the headscale magic subdomain resolve via Tailscale's MagicDNS (`100.100.100.100`) |
| `outputs.tf` | `kv_mount_path` (read by downstream deployments after bootstrap) |

Config templates live at `../data/vault/vault.hcl.tpl` and
`../data/scripts/unseal.sh.tpl`.

## Gotchas

- **Unseal key is a placeholder on first deploy**. The auto-unseal
  sidecar will loop until `vault-conf` imports the real unseal key
  into its own state and applies. See `../vault-conf/README.md` for
  the bootstrap steps.
- **PVC has `prevent_destroy = true`**. Remove the lifecycle block
  before running `destroy`.
- **CoreDNS custom ConfigMap** (`coredns-custom` in `kube-system`)
  must keep that exact name. K3s's CoreDNS loads it by convention.
- **Network policy** allows ingress only from the `vault` and
  `vault-csi` namespaces on port 8200. Egress is unrestricted, which
  Tailscale, DNS, and the Kubernetes API all require.
- **Token reviewer ClusterRole** is created here but used by
  `vault-conf` to configure the Kubernetes auth backend. The
  long-lived SA token is created in `vault-conf/auth.tf`.
