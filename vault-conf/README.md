# Vault Configuration

Configures Vault after the server is deployed. Sets up Kubernetes auth, the KV secrets engine, and the unseal key secret.

## What it manages

- **Kubernetes auth backend** -- allows pods to authenticate with Vault using their service account tokens. Creates a long-lived SA token for Vault's TokenReview API calls.
- **KV-v2 secrets engine** -- mounted at `secret/`. All downstream deployments (nextcloud, monitoring) reference this mount path via remote state.
- **Unseal key secret** -- stores the real unseal key in a Kubernetes secret so the auto-unseal sidecar in the vault pod can unseal Vault on restart.

## Files

- `auth.tf` -- Kubernetes auth backend, service account token, backend config.
- `kv.tf` -- KV-v2 mount and unseal key secret.
- `main.tf` -- Vault and Kubernetes provider config.
- `outputs.tf` -- Exports `kv_mount_path` for downstream deployments.

## Bootstrap procedure

Vault requires manual bootstrapping before this deployment can be applied:

1. Apply the `vault` deployment. It creates a placeholder unseal key secret with a dummy value. The auto-unseal sidecar will spin because the key is wrong.
2. Manually initialize Vault (`vault operator init`) and unseal it.
3. Import the existing unseal key secret into vault-conf state:
   ```
   ./terraform.sh vault-conf import kubernetes_secret.vault_unseal_keys vault/vault-unseal-keys
   ```
4. Apply vault-conf with the real unseal key and root token. This overwrites the dummy key so the auto-unseal sidecar works on future restarts.

The `vault` deployment has `ignore_changes = [data]` on its copy of the secret so it never reverts the real key back to the dummy.

## Gotchas

- **Root token**: The Vault provider authenticates with `vault_root_token`. This is expected -- vault-conf is bootstrap-level configuration.
- **Dual ownership of unseal secret**: Both `vault` and `vault-conf` have a `kubernetes_secret.vault_unseal_keys` resource. The vault deployment owns the initial creation; vault-conf owns the data after import. Don't destroy vault-conf without understanding this.
- **Single unseal key**: Only one key (`key1`) is stored, implying a shamir threshold of 1.
