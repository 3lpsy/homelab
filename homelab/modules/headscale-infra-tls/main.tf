

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

# difficulty updating when server_url changes
resource "acme_certificate" "main" {
  account_key_pem           = acme_registration.main.account_key_pem
  common_name               = var.server_domain
  subject_alternative_names = []

  dns_challenge {
    provider = "route53"
    config = {
      AWS_ACCESS_KEY_ID     = var.aws_access_key
      AWS_SECRET_ACCESS_KEY = var.aws_secret_key
      AWS_REGION            = var.aws_region
    }
  }
  lifecycle {
    replace_triggered_by = [acme_registration.main]
  }
}
