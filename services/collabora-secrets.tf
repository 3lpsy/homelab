resource "random_password" "collabora_password" {
  length  = 32
  special = false
}

resource "headscale_pre_auth_key" "collabora_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.collabora_server_user
  reusable       = true
  time_to_expire = "1y"
}

resource "kubernetes_secret" "collabora_tailscale_auth" {
  metadata {
    name      = "collabora-tailscale-auth"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  type = "Opaque"

  data = {
    TS_AUTHKEY = headscale_pre_auth_key.collabora_server.key
  }
}

module "collabora-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = {
    acme = acme
  }
}

resource "vault_kv_secret_v2" "collabora_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "nextcloud/collabora-tls"

  data_json = jsonencode({
    fullchain_pem = module.collabora-tls.fullchain_pem
    privkey_pem   = module.collabora-tls.privkey_pem
  })

  # tls-rotator (services/tls-rotator.tf) owns rotation post-bootstrap.
  lifecycle {
    ignore_changes = [data_json]
  }
}
