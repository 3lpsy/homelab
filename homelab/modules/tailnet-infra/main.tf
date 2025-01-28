terraform {
  required_providers {
    headscale = {
      source  = "awlsring/headscale"
      version = "=0.2.0"
            configuration_aliases = [ headscale ]
    }
  }
}

data "local_file" "api_key" {
  filename = "${path.root}/../headscale.key"
}


resource "headscale_user" "personal_user" {
  name = var.personal_username
  lifecycle {
    prevent_destroy = true
  }
}
resource "headscale_user" "mobile_user" {
  name = var.mobile_username
  lifecycle {
    prevent_destroy = true
  }
}

resource "headscale_user" "tablet_user" {
  name = var.tablet_username
  lifecycle {
    prevent_destroy = true
  }
}

resource "headscale_user" "deck_user" {
  name = var.deck_username
  lifecycle {
    prevent_destroy = true
  }
}
resource "headscale_user" "nomad_server_user" {
  name = var.nomad_server_username
}
resource "headscale_user" "vault_server_user" {
  name = var.vault_server_username
}

resource "headscale_pre_auth_key" "nomad_server" {
  user = var.nomad_server_username
}
resource "headscale_pre_auth_key" "vault_server" {
  user = var.vault_server_username
}
