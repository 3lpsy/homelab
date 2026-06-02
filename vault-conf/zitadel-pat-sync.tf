# pat-sync: a long-running sidecar in the zitadel pod that reads
# /zitadel/bootstrap/{login-client,tf-provider}.pat (written once at first
# instance bootstrap) and pushes them into Vault KV at
# secret/zitadel/{login-client,tf-provider}-pat.
#
# Why a sidecar (not a Job): the bootstrap PVC is RWO, already mounted by
# zitadel + login containers. A separate Job pod can't co-mount it, so the
# sync has to live inside the same pod. Sidecar polls every 5 minutes —
# PATs never change so re-writes are no-ops, but the loop self-heals if
# Vault was unreachable on first pass.

resource "vault_policy" "zitadel_pat_sync" {
  name = "zitadel-pat-sync"

  policy = <<EOT
path "${vault_mount.kv.path}/data/zitadel/login-client-pat" {
  capabilities = ["create", "update"]
}
path "${vault_mount.kv.path}/data/zitadel/tf-provider-pat" {
  capabilities = ["create", "update"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "zitadel_pat_sync" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "zitadel-pat-sync"
  bound_service_account_names      = [kubernetes_service_account.zitadel.metadata[0].name]
  bound_service_account_namespaces = [kubernetes_namespace.oidc.metadata[0].name]
  token_policies                   = [vault_policy.zitadel_pat_sync.name]
  token_ttl                        = 3600
}

resource "kubernetes_config_map" "pat_sync_script" {
  metadata {
    name      = "pat-sync-script"
    namespace = kubernetes_namespace.oidc.metadata[0].name
  }
  data = {
    # NOTE: this is a TF heredoc, so $${...} = literal ${...} for the shell.
    # Bare $f / $name / $VAULT_TOKEN are fine — TF only interprets ${...}.
    "sync.sh" = <<-EOT
      #!/bin/sh
      set -eu

      # Vault NetworkPolicy admits only the vault-csi namespace on :8200.
      # We dial the public TLS listener on :8201 instead via host_aliases
      # pinning the tailnet FQDN to the in-cluster Service ClusterIP — the
      # cert validates because SNI carries the FQDN, no CA bundle gymnastics.
      VAULT_ADDR="https://vault.${var.headscale_subdomain}.${var.headscale_magic_domain}:8201"
      export VAULT_ADDR

      echo "pat-sync: waiting for both PAT files to land on bootstrap PVC..."
      while ! [ -f /zitadel/bootstrap/login-client.pat ] || ! [ -f /zitadel/bootstrap/tf-provider.pat ]; do
        sleep 5
      done
      echo "pat-sync: both PATs present, entering sync loop"

      while true; do
        # Re-login each cycle so an expired token doesn't strand the loop.
        VAULT_TOKEN=$(vault write -field=token \
          auth/kubernetes/login \
          role=zitadel-pat-sync \
          jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token) || {
            echo "pat-sync: vault login failed, retrying"
            sleep 30
            continue
        }
        export VAULT_TOKEN

        for f in /zitadel/bootstrap/*.pat; do
          [ -f "$f" ] || continue
          name=$(basename "$f" .pat)
          if vault kv put ${vault_mount.kv.path}/zitadel/$${name}-pat \
              pat="$(cat "$f")" >/dev/null 2>&1; then
            echo "pat-sync: synced $name"
          else
            echo "pat-sync: failed to sync $name"
          fi
        done

        unset VAULT_TOKEN
        sleep 300
      done
    EOT
  }
}
