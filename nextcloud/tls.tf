module "nextcloud-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = {
    acme = acme
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

module "immich-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.immich_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

# PiHole
module "pihole-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.pihole_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

# Registry
module "registry-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.registry_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

# Radicale
module "radicale-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.radicale_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}
