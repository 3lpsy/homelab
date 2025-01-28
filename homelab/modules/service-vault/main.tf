
terraform {
  required_providers {
    # The provider is declared here just like any provider...
    nomad = {
      source  = "hashicorp/nomad"
      version = "~> 2.0"
    }
  }
}


resource "nomad_job" "main" {
  jobspec = templatefile("${path.root}/../data/jobspecs/vault.hcl", {
    tailnet_auth_key        = var.tailnet_auth_key
    headscale_server_domain = var.headscale_server_domain
    headscale_tag           = var.headscale_tag
    hostname                = var.hostname
    check_url               = "http://${var.hostname}.${var.headscale_magic_domain}"
  })
}
