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
      version = "~> 0.4.0"
    }
    acme = {
      source  = "vancluever/acme"
      version = "~> 2.0"
    }
  }
}


data "terraform_remote_state" "homelab" {
  backend = "local"
  config = {
    path = "./../homelab/terraform.tfstate"
  }
}

data "terraform_remote_state" "vault" {
  backend = "local"
  config = {
    path = "./../vault/terraform.tfstate"
  }
}

data "terraform_remote_state" "vault_conf" {
  backend = "local"
  config = {
    path = "./../vault-conf/terraform.tfstate"
  }
}
