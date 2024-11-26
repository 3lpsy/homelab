

terraform {
  required_providers {
    # The provider is declared here just like any provider...
    acme = {
      source  = "vancluever/acme"
      version = "~> 2.0"
    }
  }
}
provider "acme" {
  server_url = var.acme_server_url
}
# Generate a Private Key for the ACME Account
resource "tls_private_key" "main" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "acme_registration" "main" {
  email_address   = var.registration_email_address
  account_key_pem = tls_private_key.main.private_key_pem
}
