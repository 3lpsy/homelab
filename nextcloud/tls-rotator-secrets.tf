# Namespace, ServiceAccount, RBAC, Vault wiring, and CSI mount for the
# tls-rotator worker. The worker runs in its own namespace so its Vault
# policy (which can write to every per-service `<svc>/tls` path) is isolated
# from the consuming workloads.
#
# The worker writes rotated certs back to Vault. Vault's NetworkPolicy only
# admits the vault-csi namespace on 8200, so writes go to vault's TLS
# listener on 8201 via the cluster network. The Job pod uses host_aliases
# to pin `vault.<hs>.<magic>` to the vault Service ClusterIP so SNI + cert
# validation continue to work; cross-ns ingress is permitted by
# vault_cross_ns in vault/vault-network.tf.

resource "kubernetes_namespace" "tls_rotator" {
  metadata {
    name = "tls-rotator"
  }
}

resource "kubernetes_service_account" "tls_rotator" {
  metadata {
    name      = "tls-rotator"
    namespace = kubernetes_namespace.tls_rotator.metadata[0].name
  }
  automount_service_account_token = true
}

# Pull secret so the worker pod can fetch its image from the in-cluster
# registry (which lives on the tailnet via the registry namespace).
resource "kubernetes_secret" "tls_rotator_registry_pull_secret" {
  metadata {
    name      = "registry-pull-secret"
    namespace = kubernetes_namespace.tls_rotator.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${local.thunderbolt_registry}" = {
          username = "internal"
          password = random_password.registry_user_passwords["internal"].result
          auth     = base64encode("internal:${random_password.registry_user_passwords["internal"].result}")
        }
      }
    })
  }
}

# ACME account material for the worker. Reuses the existing account from the
# homelab module so we share rate-limit accounting with TF-issued certs.
resource "vault_kv_secret_v2" "tls_rotator_acme_account" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "tls-rotator/acme-account"
  data_json = jsonencode({
    email           = data.terraform_remote_state.homelab.outputs.acme_registration_email
    account_key_pem = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  })
}

# Vault policy: read its own creds + read/create/update on every per-service
# tls path the worker rotates. Paths come from local.rotated_certs in
# tls-rotator.tf so the policy and the worker's manifest stay in sync.
resource "vault_policy" "tls_rotator" {
  name = "tls-rotator-policy"

  policy = join("\n", concat(
    [
      <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/tls-rotator/aws" {
  capabilities = ["read"]
}
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/tls-rotator/acme-account" {
  capabilities = ["read"]
}
EOT
    ],
    [
      for c in local.rotated_certs :
      <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/${c.vault_path}" {
  capabilities = ["read", "create", "update"]
}
EOT
    ]
  ))
}

resource "vault_kubernetes_auth_backend_role" "tls_rotator" {
  backend                          = "kubernetes"
  role_name                        = "tls-rotator"
  bound_service_account_names      = [kubernetes_service_account.tls_rotator.metadata[0].name]
  bound_service_account_namespaces = [kubernetes_namespace.tls_rotator.metadata[0].name]
  token_policies                   = [vault_policy.tls_rotator.name]
  token_ttl                        = 3600
}
