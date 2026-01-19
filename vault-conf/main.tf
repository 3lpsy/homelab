terraform {
  required_providers {
    # ... your existing providers
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
  address = "https://vault.${var.headscale_magic_domain}:8201"
  token   = var.vault_root_token # Store this in a variable or use VAULT_TOKEN env var
}

provider "kubernetes" {
  config_path = pathexpand("~/.config/kube/config")
}

data "terraform_remote_state" "vault" {
  backend = "local"
  config = {
    path = "../vault/terraform.tfstate"
  }
}

# Enable Kubernetes auth
resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
}

# Get K8s auth configuration from your vault pod
data "kubernetes_service_account" "vault" {
  metadata {
    name      = data.terraform_remote_state.vault.outputs.vault_service_account_name
    namespace = data.terraform_remote_state.vault.outputs.vault_namespace
  }
}

resource "vault_kubernetes_auth_backend_config" "k8s" {
  backend              = vault_auth_backend.kubernetes.path
  kubernetes_host      = "https://kubernetes.default.svc:443"
  disable_local_ca_jwt = false
}

# Enable KV secrets engine
resource "vault_mount" "kv" {
  path = "secret"
  type = "kv-v2"
}
