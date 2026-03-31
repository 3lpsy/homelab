terraform {
  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.0"
    }
  }
}

provider "grafana" {
  url  = "https://${var.grafana_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  auth = "${var.grafana_admin_user}:${data.terraform_remote_state.monitoring.outputs.grafana_admin_password}"
}
