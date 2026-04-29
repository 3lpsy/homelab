# Shared Vault wiring for the registry-proxy namespace. Both pods use the
# same ServiceAccount, so they share the same Vault role/policy. Per-cert
# SecretProviderClasses live alongside the per-upstream Deployments
# (registry-{dockerio,ghcrio}.tf) so each pod only mounts its own cert.

resource "vault_policy" "registry_proxy" {
  name = "registry-proxy-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/registry-dockerio/*" {
  capabilities = ["read"]
}
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/registry-ghcrio/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "registry_proxy" {
  backend                          = "kubernetes"
  role_name                        = "registry-proxy"
  bound_service_account_names      = ["registry-proxy"]
  bound_service_account_namespaces = ["registry-proxy"]
  token_policies                   = [vault_policy.registry_proxy.name]
  token_ttl                        = 86400
}
