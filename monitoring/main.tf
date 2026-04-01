# PREREQUISITE: Add a "grafana" headscale user to your homelab project's
# tailnet-infra module and expose it in the user_map output before applying.

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    headscale = {
      source  = "awlsring/headscale"
      version = "~> 0.5.0"
    }
    acme = {
      source  = "vancluever/acme"
      version = "~> 2.0"
    }
  }
}

provider "kubernetes" {
  config_path = pathexpand(var.kubeconfig_path)
}

provider "vault" {
  address = "https://vault.${var.headscale_subdomain}.${var.headscale_magic_domain}:8201"
  token   = var.vault_root_token
}

provider "headscale" {
  endpoint = "https://${data.terraform_remote_state.homelab.outputs.headscale_server_fqdn}"
  api_key  = var.headscale_api_key
}

provider "acme" {
  server_url = var.acme_server_url
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
}
