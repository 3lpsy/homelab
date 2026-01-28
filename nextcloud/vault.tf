
# Store TLS certs in Vault
resource "vault_kv_secret_v2" "nextcloud_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "nextcloud/tls"

  data_json = jsonencode({
    fullchain_pem = module.nextcloud-tls.fullchain_pem
    privkey_pem   = module.nextcloud-tls.privkey_pem
  })
}

# Store Collabora TLS certs in Vault
resource "vault_kv_secret_v2" "collabora_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "nextcloud/collabora-tls"

  data_json = jsonencode({
    fullchain_pem = module.collabora-tls.fullchain_pem
    privkey_pem   = module.collabora-tls.privkey_pem
  })
}

# Store secrets in Vault
resource "vault_kv_secret_v2" "nextcloud" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "nextcloud/config"

  data_json = jsonencode({
    admin_password     = random_password.nextcloud_admin.result
    postgres_password  = random_password.postgres_password.result
    redis_password     = random_password.redis_password.result
    collabora_password = random_password.collabora_password.result
  })
}



# Store HaRP secret in Vault
resource "vault_kv_secret_v2" "harp" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "nextcloud/harp"

  data_json = jsonencode({
    shared_key = random_password.harp_shared_key.result
  })
}

# Create Vault policy for Nextcloud
resource "vault_policy" "nextcloud" {
  name = "nextcloud-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/*" {
  capabilities = ["read"]
}
EOT
}

# Create Vault role for Nextcloud
resource "vault_kubernetes_auth_backend_role" "nextcloud" {
  backend                          = "kubernetes"
  role_name                        = "nextcloud"
  bound_service_account_names      = ["nextcloud"]
  bound_service_account_namespaces = ["nextcloud"]
  token_policies                   = [vault_policy.nextcloud.name]
  token_ttl                        = 86400
}
