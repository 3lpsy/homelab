resource "random_password" "harp_shared_key" {
  length  = 32
  special = false
}

resource "vault_kv_secret_v2" "harp" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "nextcloud/harp"

  data_json = jsonencode({
    shared_key = random_password.harp_shared_key.result
  })
}
