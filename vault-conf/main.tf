terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

provider "vault" {
  address = "https://vault.${var.headscale_subdomain}.${var.headscale_magic_domain}:8201"
  token   = var.vault_root_token
}

provider "kubernetes" {
  config_path = pathexpand("~/.config/kube/config")
}


resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
}

data "kubernetes_service_account" "vault" {
  metadata {
    name      = data.terraform_remote_state.vault.outputs.vault_service_account_name
    namespace = data.terraform_remote_state.vault.outputs.vault_namespace
  }
}

resource "kubernetes_secret" "vault_token" {
  metadata {
    name      = "vault-token"
    namespace = data.terraform_remote_state.vault.outputs.vault_namespace
    annotations = {
      "kubernetes.io/service-account.name" = data.kubernetes_service_account.vault.metadata[0].name
    }
  }

  type = "kubernetes.io/service-account-token"

  wait_for_service_account_token = true
}

resource "vault_kubernetes_auth_backend_config" "k8s" {
  backend              = vault_auth_backend.kubernetes.path
  kubernetes_host      = "https://kubernetes.default.svc:443"
  kubernetes_ca_cert   = kubernetes_secret.vault_token.data["ca.crt"]
  token_reviewer_jwt   = kubernetes_secret.vault_token.data["token"]
  disable_local_ca_jwt = false
}

resource "vault_mount" "kv" {
  path = "secret"
  type = "kv-v2"
}

resource "kubernetes_secret" "vault_unseal_keys" {
  metadata {
    name      = "vault-unseal-keys"
    namespace = data.terraform_remote_state.vault.outputs.vault_namespace
  }
  type = "Opaque"
  data = {
    key1 = var.vault_unseal_key
  }
}
