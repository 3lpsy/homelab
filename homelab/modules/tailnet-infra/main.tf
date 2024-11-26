terraform {
  required_providers {
    headscale = {
      source  = "awlsring/headscale"
      version = "=0.2.0"
    }
  }
}

data "local_file" "api_key" {
  filename = "${path.root}/../headscale.key"
}

provider "headscale" {
  endpoint = "https://${var.headscale_server_domain}"
  api_key  = var.api_key
}

resource "headscale_user" "personal_user" {
  name = var.personal_username
  lifecycle {
    prevent_destroy = true
  }
}

# Creates the user terraform
resource "headscale_user" "nomad_server_user" {
  name = var.nomad_server_username
}

# Creates the user terraform
resource "headscale_user" "mobile_user" {
  name = var.mobile_user
}


# A pre auth key that expires in the default 1 hour
resource "headscale_pre_auth_key" "nomad_server" {
  user = var.nomad_server_username
}
