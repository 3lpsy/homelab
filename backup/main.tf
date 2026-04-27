terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

provider "kubernetes" {
  config_path = pathexpand(var.kubeconfig_path)
}

resource "kubernetes_namespace" "velero" {
  metadata {
    name = "velero"
    labels = {
      name                   = "velero"
      "app.kubernetes.io/name" = "velero"
    }
  }
}
