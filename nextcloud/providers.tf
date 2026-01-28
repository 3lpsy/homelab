provider "kubernetes" {
  config_path = pathexpand("/home/vanguard/.config/kube/config")
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
