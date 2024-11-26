

terraform {
  required_providers {
    # The provider is declared here just like any provider...
    acme = {
      source  = "vancluever/acme"
      version = "~> 2.0"
    }
  }
}

# difficulty updating when server_url changes
resource "acme_certificate" "main" {
  account_key_pem           = var.account_key_pem
  common_name               = var.server_domain
  recursive_nameservers     = var.recursive_nameservers
  subject_alternative_names = []
  dns_challenge {
    provider = "route53"
    config = {
      AWS_ACCESS_KEY_ID     = var.aws_access_key
      AWS_SECRET_ACCESS_KEY = var.aws_secret_key
      AWS_REGION            = var.aws_region
    }
  }

}
