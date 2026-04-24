# Vault Configuration

Configures Vault after the server is up. Sets up the Kubernetes auth
backend, the KV-v2 secrets engine, and writes the real unseal key into
the Kubernetes secret that the auto-unseal sidecar watches.

## What it manages

- **Kubernetes auth backend**. Lets pods authenticate to Vault with
  their service account tokens. Creates a long-lived SA token for the
  backend to call Kubernetes' TokenReview API.
- **KV-v2 secrets engine**. Mounted at `secret/`. All downstream
  deployments reference this mount path via `outputs.kv_mount_path`
  read from this deployment's remote state.
- **Unseal key secret**. Stores the real unseal key in the
  `vault-unseal-keys` Kubernetes secret so the auto-unseal sidecar in
  the Vault pod can unseal on restart.

## Files

- `main.tf` -- Vault and Kubernetes provider config.
- `auth.tf` -- Kubernetes auth backend, long-lived SA token,
  `vault_kubernetes_auth_backend_config`.
- `kv.tf` -- `vault_mount "kv"` plus the `vault-unseal-keys` secret.
- `outputs.tf` -- Exports `kv_mount_path` for downstream deployments.

## Bootstrap procedure

Vault requires a one-time manual bootstrap before this deployment can
apply cleanly:

1. Apply the `vault` deployment. It creates a placeholder
   `vault-unseal-keys` secret with a dummy value; the auto-unseal
   sidecar will loop because the key is wrong.
2. Initialize Vault (`vault operator init`) and unseal it manually.
   Record the real unseal key and root token.
3. Import the existing secret into `vault-conf` state so Terraform
   knows it owns the data:

   ```
   ./terraform.sh vault-conf import kubernetes_secret.vault_unseal_keys vault/vault-unseal-keys
   ```

4. Set the real unseal key and root token in `.env`, then apply
   `vault-conf`. The apply overwrites the dummy key with the real
   one, wires up the Kubernetes auth backend, and mounts the KV-v2
   engine.

The `vault` deployment has `ignore_changes = [data]` on its own copy
of the unseal-keys secret so that future `vault apply` runs never
revert the real key back to the dummy.

## Gotchas

- **Root token auth**. The Vault provider in this deployment
  authenticates as root. That is intentional: this is bootstrap-level
  configuration, and no other deployment needs root.
- **Dual ownership of the unseal-keys secret**. Both `vault` and
  `vault-conf` declare `kubernetes_secret.vault_unseal_keys`. `vault`
  creates it with a dummy value on first apply. `vault-conf` imports
  it and then owns the data. Do not destroy `vault-conf` without
  understanding that the secret will revert to whatever `vault`
  currently declares.
- **Single unseal key**. Only `key1` is stored, which implies the
  Shamir threshold is 1. Good enough for a single-operator homelab;
  do not copy this into anything that matters.
