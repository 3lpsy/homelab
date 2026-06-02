provider "kubernetes" {
  config_path = pathexpand(var.kubeconfig_path)
}

provider "vault" {
  address = "https://vault.${var.headscale_subdomain}.${var.headscale_magic_domain}:8201"
  token   = var.vault_root_token # Store this in a variable or use VAULT_TOKEN env var
}

provider "headscale" {
  endpoint = "https://${data.terraform_remote_state.homelab.outputs.headscale_server_fqdn}"
  api_key  = var.headscale_api_key
}

provider "acme" {
  server_url = var.acme_server_url
}

provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
}

# Zitadel core API. PAT is the IAM_OWNER service-user token created at
# first-instance bootstrap (vault-conf/zitadel.tf), shipped to Vault by
# the pat-sync sidecar (vault-conf/zitadel-pat-sync.tf).
data "vault_kv_secret_v2" "zitadel_tf_provider_pat" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "zitadel/tf-provider-pat"
}

provider "zitadel" {
  domain       = "${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  insecure     = false
  port         = "443"
  # `token` is deprecated and tries to interpret the value as a JWT file
  # path. PATs go through `access_token`.
  access_token = data.vault_kv_secret_v2.zitadel_tf_provider_pat.data["pat"]
}
