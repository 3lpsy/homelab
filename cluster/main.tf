terraform {
  required_providers {
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

provider "headscale" {
  endpoint = "https://${data.terraform_remote_state.homelab.outputs.headscale_server_fqdn}"
  api_key  = var.headscale_api_key
}
