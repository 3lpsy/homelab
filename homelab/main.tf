terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}



# Configure the AWS Provider
provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
}

module "headscale-infra" {
  source      = "./modules/headscale-infra"
  ami         = "ami-0557a15b87f6559cf"
  ec2_user    = "ubuntu"
  ssh_pub_key = trimspace(file(var.ssh_pub_key_path))
}

module "headscale-infra-dns" {
  source                  = "./modules/headscale-infra-dns"
  headscale_server_domain = var.headscale_server_domain
  headscale_magic_domain  = var.headscale_magic_domain
  headscale_server_ip     = module.headscale-infra.public_ip
}

module "headscale-infra-tls" {
  source                     = "./modules/headscale-infra-tls"
  server_domain              = module.headscale-infra-dns.dns_domain
  registration_email_address = var.registration_email_address
  aws_region                 = var.aws_region
  aws_access_key             = var.aws_access_key
  aws_secret_key             = var.aws_secret_key
}

module "headscale-provision-tls" {
  source            = "./modules/headscale-provision-tls"
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
  source           = "./modules/headscale-provision-nginx"
  server_ip        = module.headscale-infra.public_ip
  ssh_user         = module.headscale-infra.ssh_user
  ssh_priv_key     = trimspace(file(var.ssh_priv_key_path))
  headscale_domain = module.headscale-infra-tls.certificate_domain
  depends_on       = [module.headscale-infra-tls, module.headscale-provision-dep]
}

module "headscale-provision-headscale" {
  source                  = "./modules/headscale-provision-headscale"
  server_ip               = module.headscale-infra.public_ip
  ssh_user                = module.headscale-infra.ssh_user
  ssh_priv_key            = trimspace(file(var.ssh_priv_key_path))
  headscale_server_domain = module.headscale-infra-tls.certificate_domain
  headscale_magic_domain  = "${var.headscale_subdomain}.${var.headscale_magic_domain}"
  depends_on              = [module.headscale-infra-tls, module.headscale-provision-dep]
}
