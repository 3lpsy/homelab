# Secrets, Policies and Auth Backends

# Secrets

resource "vault_kv_secret_v2" "nextcloud_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "nextcloud/tls"

  data_json = jsonencode({
    fullchain_pem = module.nextcloud-tls.fullchain_pem
    privkey_pem   = module.nextcloud-tls.privkey_pem
  })
}

resource "vault_kv_secret_v2" "collabora_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "nextcloud/collabora-tls"

  data_json = jsonencode({
    fullchain_pem = module.collabora-tls.fullchain_pem
    privkey_pem   = module.collabora-tls.privkey_pem
  })
}

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

resource "vault_kv_secret_v2" "harp" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "nextcloud/harp"

  data_json = jsonencode({
    shared_key = random_password.harp_shared_key.result
  })
}


resource "vault_kv_secret_v2" "immich_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "nextcloud/immich"
  data_json = jsonencode({
    db_password = random_password.immich_db_password.result
  })
}

resource "vault_kv_secret_v2" "immich_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "nextcloud/immich-tls"
  data_json = jsonencode({
    fullchain_pem = module.immich-tls.fullchain_pem
    privkey_pem   = module.immich-tls.privkey_pem
  })
}


resource "vault_kv_secret_v2" "pihole_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "pihole/config"
  data_json = jsonencode({
    admin_password = random_password.pihole_password.result
  })
}

resource "vault_kv_secret_v2" "pihole_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "pihole/tls"
  data_json = jsonencode({
    fullchain_pem = module.pihole-tls.fullchain_pem
    privkey_pem   = module.pihole-tls.privkey_pem
  })
}

resource "vault_kv_secret_v2" "registry_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "registry/config"
  data_json = jsonencode({
    users = {
      for user in var.registry_users :
      user => random_password.registry_user_passwords[user].result
    }
  })
}

# Registry htpasswd
resource "vault_kv_secret_v2" "registry_htpasswd" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "registry/htpasswd"
  data_json = jsonencode({
    htpasswd = join("\n", [
      for user in var.registry_users :
      "${user}:${bcrypt(random_password.registry_user_passwords[user].result)}"
    ])
  })
  # Avoid regenerating at each TF apply. May need to modify when new users added
  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "vault_kv_secret_v2" "registry_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "registry/tls"
  data_json = jsonencode({
    fullchain_pem = module.registry-tls.fullchain_pem
    privkey_pem   = module.registry-tls.privkey_pem
  })
}

# Radicale

resource "vault_kv_secret_v2" "radicale_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "radicale/config"
  data_json = jsonencode({
    radicale_password = random_password.radicale_password.result
  })
}

resource "vault_kv_secret_v2" "radicale_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "radicale/tls"
  data_json = jsonencode({
    fullchain_pem = module.radicale-tls.fullchain_pem
    privkey_pem   = module.radicale-tls.privkey_pem
  })
}


# Policies

resource "vault_policy" "nextcloud" {
  name = "nextcloud-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_policy" "pihole" {
  name = "pihole-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/pihole/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_policy" "registry" {
  name = "registry-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/registry/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_policy" "radicale" {
  name = "radicale-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/radicale/*" {
  capabilities = ["read"]
}
EOT
}



# Auth Backend
resource "vault_kubernetes_auth_backend_role" "nextcloud" {
  backend                          = "kubernetes"
  role_name                        = "nextcloud"
  bound_service_account_names      = ["nextcloud"]
  bound_service_account_namespaces = ["nextcloud"]
  token_policies                   = [vault_policy.nextcloud.name]
  token_ttl                        = 86400
}

resource "vault_kubernetes_auth_backend_role" "pihole" {
  backend                          = "kubernetes"
  role_name                        = "pihole"
  bound_service_account_names      = ["pihole"]
  bound_service_account_namespaces = ["pihole"]
  token_policies                   = [vault_policy.pihole.name]
  token_ttl                        = 86400
}

resource "vault_kubernetes_auth_backend_role" "registry" {
  backend                          = "kubernetes"
  role_name                        = "registry"
  bound_service_account_names      = ["registry"]
  bound_service_account_namespaces = ["registry"]
  token_policies                   = [vault_policy.registry.name]
  token_ttl                        = 86400
}


resource "vault_kubernetes_auth_backend_role" "radicale" {
  backend                          = "kubernetes"
  role_name                        = "radicale"
  bound_service_account_names      = ["radicale"]
  bound_service_account_namespaces = ["radicale"]
  token_policies                   = [vault_policy.radicale.name]
  token_ttl                        = 86400
}
