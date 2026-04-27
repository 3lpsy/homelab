# Join node to the tailnet (initial connection uses LAN IP)
module "tailnet-provision-node" {
  source                  = "./modules/tailnet-provision-node"
  server_ip               = var.node_server_ip
  ssh_user                = var.node_ssh_user
  ssh_priv_key            = trimspace(file(var.ssh_priv_key_path))
  nomad_hostname          = var.node_host_name
  headscale_server_domain = data.terraform_remote_state.homelab.outputs.headscale_server_fqdn
  tailnet_auth_key        = data.terraform_remote_state.homelab.outputs.node_preauth_key

  providers = {
    headscale = headscale
  }
}

# After tailnet join, all subsequent connections use the Tailscale hostname
module "node-infra-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.node_host_name}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  depends_on = [module.tailnet-provision-node]
  providers = {
    acme = acme
  }
}

module "node-provision-tls" {
  source            = "./../templates/provision-tls"
  server_ip         = "${var.node_host_name}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  ssh_user          = var.node_ssh_user
  ssh_priv_key      = trimspace(file(var.ssh_priv_key_path))
  domain            = module.node-infra-tls.certificate_domain
  tls_privkey_pem   = module.node-infra-tls.privkey_pem
  tls_fullchain_pem = module.node-infra-tls.fullchain_pem
  depends_on        = [module.node-infra-tls]
}

module "node-provision-dep" {
  source       = "./modules/node-provision-dep"
  server_ip    = module.node-infra-tls.certificate_domain
  ssh_user     = var.node_ssh_user
  ssh_priv_key = trimspace(file(var.ssh_priv_key_path))
  depends_on   = [module.tailnet-provision-node, module.node-infra-tls]
}

module "cluster-provision" {
  source                    = "./modules/node-provision-server"
  host                      = module.node-infra-tls.certificate_domain
  ssh_user                  = var.node_ssh_user
  ssh_priv_key              = trimspace(file(var.ssh_priv_key_path))
  nomad_host_name           = var.node_host_name
  headscale_magic_subdomain = "${var.headscale_subdomain}.${var.headscale_magic_domain}"
  registry_domain           = data.terraform_remote_state.homelab.outputs.tailnet_user_name_map["registry_server_user"]
  registry_proxy_domain     = data.terraform_remote_state.homelab.outputs.tailnet_user_name_map["registry_proxy_server_user"]
  depends_on                = [module.node-provision-dep]
}
