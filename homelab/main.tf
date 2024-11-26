terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    # The provider is declared here just like any provider...
    acme = {
      source  = "vancluever/acme"
      version = "~> 2.0"
    }
  }
}

provider "acme" {
  server_url = var.acme_server_url
}
# Configure the AWS Provider
provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
}

module "homelab-infra-tls" {
  source                     = "./modules/homelab-infra-tls"
  registration_email_address = var.registration_email_address
}

module "headscale-infra" {
  source             = "./modules/headscale-infra"
  ami                = "ami-0557a15b87f6559cf"
  ec2_user           = "ubuntu"
  ssh_pub_key        = trimspace(file(var.ssh_pub_key_path))
  backup_bucket_name = var.homelab_bucket_name
}

module "headscale-infra-dns" {
  source                  = "./modules/headscale-infra-dns"
  headscale_server_domain = var.headscale_server_domain
  headscale_magic_domain  = var.headscale_magic_domain
  headscale_server_ip     = module.headscale-infra.public_ip
}



module "headscale-infra-tls" {
  source                = "./templates/infra-tls"
  account_key_pem       = module.homelab-infra-tls.account_key_pem
  server_domain         = module.headscale-infra-dns.dns_domain
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  depends_on = [module.headscale-infra-dns]
  providers = {
    acme = acme
  }
}


module "headscale-provision-tls" {
  source            = "./templates/provision-tls"
  server_ip         = module.headscale-infra.public_ip
  ssh_user          = module.headscale-infra.ssh_user
  ssh_priv_key      = trimspace(file(var.ssh_priv_key_path))
  domain            = module.headscale-infra-tls.certificate_domain
  tls_privkey_pem   = module.headscale-infra-tls.privkey_pem
  tls_fullchain_pem = module.headscale-infra-tls.fullchain_pem
}

module "headscale-provision-dep" {
  source       = "./modules/headscale-provision-dep"
  server_ip    = module.headscale-infra.public_ip
  ssh_user     = module.headscale-infra.ssh_user
  ssh_priv_key = trimspace(file(var.ssh_priv_key_path))
}

module "headscale-provision-nginx" {
  source        = "./templates/provision-nginx"
  server_ip     = module.headscale-infra.public_ip
  ssh_user      = module.headscale-infra.ssh_user
  ssh_priv_key  = trimspace(file(var.ssh_priv_key_path))
  server_domain = module.headscale-infra-tls.certificate_domain
  proxy_port    = "8443"
  proxy_proto   = "https"
  nginx_user    = "www-data"
  depends_on    = [module.headscale-infra-tls, module.headscale-provision-dep]
}

module "headscale-provision-headscale" {
  source                  = "./modules/headscale-provision-headscale"
  server_ip               = module.headscale-infra.public_ip
  ssh_user                = module.headscale-infra.ssh_user
  ssh_priv_key_path       = var.ssh_priv_key_path
  headscale_server_domain = module.headscale-infra-tls.certificate_domain
  headscale_magic_domain  = "${var.headscale_subdomain}.${var.headscale_magic_domain}"
  depends_on              = [module.headscale-infra-tls, module.headscale-provision-dep]
  backup_bucket_name      = module.headscale-infra.backup_bucket_name
  personal_username       = var.tailnet_personal_username
  nomad_server_username   = var.tailnet_nomad_server_username
  mobile_username         = var.tailnet_mobile_username
}

data "local_file" "api_key" {
  filename = "${path.root}/../headscale.key"
}
# Create the personal user (if you want), the nomad user, and a preauth key for nomad
module "tailnet-infra" {
  source                  = "./modules/tailnet-infra"
  headscale_server_domain = module.headscale-infra-tls.certificate_domain
  api_key                 = var.headscale_api_key
  personal_username       = var.tailnet_personal_username
  nomad_server_username   = var.tailnet_nomad_server_username
  mobile_user             = var.tailnet_mobile_username

}

# Nomad is now on tailscale, no more server_ip usage after this
module "tailnet-provision-nomad" {
  source                  = "./modules/tailnet-provision-nomad"
  server_ip               = var.nomad_server_ip
  ssh_user                = var.nomad_ssh_user
  ssh_priv_key            = trimspace(file(var.ssh_priv_key_path))
  nomad_hostname          = var.nomad_host_name
  headscale_server_domain = module.headscale-provision-headscale.headscale_server_domain
  tailnet_auth_key        = module.tailnet-infra.nomad_server_preauth_key
  depends_on              = [module.tailnet-infra]
}

module "nomad-infra-tls" {
  source                = "./templates/infra-tls"
  account_key_pem       = module.homelab-infra-tls.account_key_pem
  server_domain         = "${var.nomad_host_name}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  depends_on = [module.headscale-infra-dns]
  providers = {
    acme = acme
  }
}

module "nomad-provision-tls" {
  source            = "./templates/provision-tls"
  server_ip         = "${var.nomad_host_name}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  ssh_user          = var.nomad_ssh_user
  ssh_priv_key      = trimspace(file(var.ssh_priv_key_path))
  domain            = module.nomad-infra-tls.certificate_domain
  tls_privkey_pem   = module.nomad-infra-tls.privkey_pem
  tls_fullchain_pem = module.nomad-infra-tls.fullchain_pem
  depends_on        = [module.nomad-infra-tls]

}

module "nomad-provision-dep" {
  source       = "./modules/nomad-provision-dep"
  server_ip    = module.nomad-infra-tls.certificate_domain
  ssh_user     = var.nomad_ssh_user
  ssh_priv_key = trimspace(file(var.ssh_priv_key_path))
  depends_on   = [module.tailnet-provision-nomad, module.nomad-infra-tls]
}

module "nomad-provision-nginx" {
  source        = "./templates/provision-nginx"
  server_ip     = module.nomad-infra-tls.certificate_domain
  ssh_user      = var.nomad_ssh_user
  ssh_priv_key  = trimspace(file(var.ssh_priv_key_path))
  server_domain = module.nomad-infra-tls.certificate_domain
  proxy_port    = "4646"
  proxy_proto   = "http"
  nginx_user    = "nginx"
  depends_on    = [module.nomad-provision-dep, module.nomad-provision-tls]
}

module "nomad-provision-server" {
  source          = "./modules/nomad-provision-server"
  host            = module.nomad-infra-tls.certificate_domain
  ssh_user        = var.nomad_ssh_user
  ssh_priv_key    = trimspace(file(var.ssh_priv_key_path))
  nomad_host_name = var.nomad_host_name
  depends_on      = [module.nomad-provision-nginx]
}

# module "nomad-provision-bootstrap" {
#   source       = "./modules/nomad-provision-bootstrap"
#   host         = module.nomad-infra-tls.certificate_domain
#   ssh_user     = var.nomad_ssh_user
#   ssh_priv_key = trimspace(file(var.ssh_priv_key_path))
#   depends_on   = [module.nomad-provision-server]
# }
# provider "nomad" {
#   address   = "https://${module.nomad-infra-tls.certificate_domain}"
#   secret_id = module.nomad-provision-bootstrap.bootstrap_token
# }
