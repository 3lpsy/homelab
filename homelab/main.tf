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
  backup_bucket_name      = module.headscale-infra.backup_bucket_name
  tailnet_users           = var.tailnet_users

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

module "exit-node-0" {
  source                  = "./modules/exit-node"
  ami                     = "ami-0b6c6ebed2801a5cb" # 24.04
  ec2_user                = "ubuntu"
  ssh_user                = "ubuntu"
  ssh_priv_key            = trimspace(file(var.ssh_priv_key_path))
  vpc_id                  = module.headscale-infra.vpc_id
  gateway_id              = module.headscale-infra.gateway_id
  ssh_pub_key             = trimspace(file(var.ssh_pub_key_path))
  headscale_server_domain = module.headscale-infra-dns.dns_domain
  tailnet_auth_key        = module.tailnet-infra.exit_node_preauth_key
  node_name               = "0"

  depends_on = [module.tailnet-infra]

}




module "litellm" {
  source                  = "./modules/litellm"
  ami                     = "ami-0b6c6ebed2801a5cb" # Ubuntu 24.04
  ec2_user                = "ubuntu"
  ssh_user                = "ubuntu"
  ssh_priv_key            = trimspace(file(var.ssh_priv_key_path))
  ssh_pub_key             = trimspace(file(var.ssh_pub_key_path))
  vpc_id                  = module.headscale-infra.vpc_id
  subnet_id               = module.exit-node-0.subnet_id
  headscale_server_domain = module.headscale-infra-dns.dns_domain
  tailnet_auth_key        = module.tailnet-infra.litellm_preauth_key
  aws_region              = var.aws_region
  bedrock_models          = var.bedrock_models

  depends_on = [module.tailnet-infra]
}

# module "ollama-server" {
#   source = "./modules/ollama"
#   ami    = "ami-029307b2e33073981" # DLAMI Ubuntu 24.04 (NVIDIA drivers pre-installed)
#   #  instance_type =   "g5.4xlarge" # 1x A10G 24GB VRAM, 16 vCPU, 64GB RAM, needs nvidia drivers
#   # instance_type = "g6e.xlarge"  # 1x L40S 48GB VRAM, 4 vCPU, 32GB RAM — $1.86/hr
#   instance_type           = "g6e.2xlarge" # 1x L40S 48GB VRAM, 8 vCPU, 64GB RAM
#   root_volume_size        = 300
#   ec2_user                = "ubuntu"
#   ssh_user                = "ubuntu"
#   ssh_priv_key            = trimspace(file(var.ssh_priv_key_path))
#   ssh_pub_key             = trimspace(file(var.ssh_pub_key_path))
#   vpc_id                  = module.headscale-infra.vpc_id
#   subnet_id               = module.exit-node-0.subnet_id
#   headscale_server_domain = module.headscale-infra-dns.dns_domain
#   tailnet_auth_key        = module.tailnet-infra.ollama_preauth_key

#   # Dense 27B — all params active per token, ~34 tok/s, best for complex reasoning/coding
#   default_model = "qwen3.5:27b"
#   # MoE 35B — only 3B active per token, ~100 tok/s, best for bulk/repetitive tasks
#   efficient_model = "qwen3.5:35b-a3b"

#   ollama_context_length = 65536  # 64K for agentic work
#   ollama_kv_cache_type  = "q8_0" # save ~40% VRAM on context
#   ollama_keep_alive     = "30m"
#   skip_nvidia_install   = true
#   depends_on            = [module.tailnet-infra]
# }
