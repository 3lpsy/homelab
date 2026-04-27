terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    acme = {
      source  = "vancluever/acme"
      version = "~> 2.0"
    }

    headscale = {
      source  = "awlsring/headscale"
      version = "~> 0.5.0"
    }
  }
}

provider "acme" {
  server_url = var.acme_server_url
}
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
  source                = "./../templates/infra-tls"
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
  source            = "./../templates/provision-tls"
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
  source        = "./../templates/provision-nginx"
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
  headscale_key_path      = var.headscale_key_path
  depends_on              = [module.headscale-infra-tls, module.headscale-provision-dep]
}

# Replaces the legacy age+S3 backup of /var/lib/headscale/db.sqlite. Captures
# /etc, /var/lib/headscale, and /root with daily kopia snapshots into the
# host-headscale/ prefix of the shared backup bucket.
module "headscale-provision-kopia" {
  source                = "./../templates/provision-kopia"
  server_ip             = module.headscale-infra.public_ip
  ssh_user              = module.headscale-infra.ssh_user
  ssh_priv_key          = trimspace(file(var.ssh_priv_key_path))
  bucket_name           = module.headscale-infra.backup_bucket_name
  bucket_region         = var.aws_region
  prefix                = local.backup_clients["headscale"]
  aws_access_key_id     = aws_iam_access_key.backup["headscale"].id
  aws_secret_access_key = aws_iam_access_key.backup["headscale"].secret
  repo_password         = random_password.backup_repo["headscale"].result
  backup_paths          = ["/etc", "/var/lib/headscale"]
  exclude_globs         = []
  on_calendar           = "daily"
  depends_on            = [module.headscale-provision-headscale]
}

data "local_file" "api_key" {
  filename = var.headscale_key_path
}


// using module.headscale-infra-tls.certificate_domain will fail to init provider on refresh
provider "headscale" {
  endpoint = "https://${module.headscale-infra-dns.dns_domain}"
  api_key  = var.headscale_api_key
}

module "tailnet-infra" {
  source                  = "./modules/tailnet-infra"
  headscale_server_domain = module.headscale-infra-tls.certificate_domain
  headscale_key_path      = var.headscale_key_path

  api_key       = var.headscale_api_key
  tailnet_users = var.tailnet_users
  providers = {
    headscale = headscale
  }
  depends_on = [module.headscale-infra-tls]
}

module "headscale-provision-tailscale" {
  source                  = "./modules/headscale-provision-tailscale"
  server_ip               = module.headscale-infra.public_ip
  ssh_user                = module.headscale-infra.ssh_user
  ssh_priv_key_path       = var.ssh_priv_key_path
  headscale_server_domain = module.headscale-infra-tls.certificate_domain
  tailnet_hostname        = "headscale-host"
  preauth_key             = module.tailnet-infra.headscale_host_preauth_key
  depends_on              = [module.headscale-provision-headscale, module.tailnet-infra]
}
