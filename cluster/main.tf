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
    # data.external.k3s_node_token reads delphi's k3s node-token over SSH so
    # artemis can join as an agent. New dependency — run `terraform.sh cluster
    # init` to pull it before the next apply.
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
    # random_password.nut_monitor — shared NUT upsmon password pushed to both
    # nodes. New dependency — run `terraform.sh cluster init` before apply.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
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
