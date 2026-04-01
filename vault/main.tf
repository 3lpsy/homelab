terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    acme = {
      source  = "vancluever/acme"
      version = "~> 2.0"
    }
    headscale = {
      source  = "awlsring/headscale"
      version = "~> 0.4.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }
}

provider "acme" {
  server_url = var.acme_server_url
}

provider "kubernetes" {
  config_path = pathexpand(var.kubeconfig_path)
}

provider "headscale" {
  endpoint = "https://${data.terraform_remote_state.homelab.outputs.headscale_server_fqdn}"
  api_key  = var.headscale_api_key
}

provider "helm" {
  kubernetes {
    config_path = pathexpand(var.kubeconfig_path)
  }
}

resource "kubernetes_namespace" "vault" {
  metadata {
    name = "vault"
    labels = {
      name = "vault"
    }
  }
}
