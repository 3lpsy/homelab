# Vault

Deploys HashiCorp Vault as a StatefulSet on K3s with file-backed storage. Exposed externally via Tailscale with TLS; cluster-internal access is plaintext on port 8200.

## Architecture

- **Internal listener** (8200) -- plaintext, ClusterIP service, used by CSI driver and in-cluster consumers.
- **External listener** (8201) -- TLS via Let's Encrypt, reachable over Tailscale only.
- **Auto-unseal sidecar** -- busybox container that polls `/v1/sys/health` and unseals when sealed. Requires a valid unseal key in the `vault-unseal-keys` secret (see vault-conf bootstrap).
- **Secrets Store CSI Driver + Vault CSI Provider** -- Helm-managed, allows pods in other namespaces to mount Vault secrets.

## File layout

| File | Contents |
|---|---|
| `vault.tf` | StatefulSet and Service |
| `vault-secrets.tf` | Service account, RBAC, Headscale pre-auth key, TLS certs, tailscale auth, unseal keys, network policy |
| `vault-config.tf` | ConfigMaps (vault.hcl, unseal script) |
| `vault-pvc.tf` | PersistentVolumeClaim |
| `csi.tf` | Secrets Store CSI Driver and Vault CSI Provider Helm releases |
| `dns.tf` | CoreDNS override for Tailscale magic domain resolution |

Config templates live in `data/vault/vault.hcl.tpl` and `data/scripts/unseal.sh.tpl`.

## Gotchas

- **Unseal key is a placeholder** on first deploy. The auto-unseal sidecar will spin until vault-conf imports and overwrites it with the real key. See vault-conf README for the bootstrap procedure.
- **PVC has `prevent_destroy`**. Remove the lifecycle block before destroying.
- **CoreDNS custom ConfigMap** (`coredns-custom`) must keep that exact name -- K3s CoreDNS loads it by convention.
- **Network policy** allows ingress only from `vault` and `vault-csi` namespaces on port 8200. Egress is unrestricted (needed for Tailscale, DNS, K8s API).
