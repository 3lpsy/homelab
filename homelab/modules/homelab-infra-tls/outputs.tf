

output "account_key_pem" {
  value     = acme_registration.main.account_key_pem
  sensitive = true
}

output "domain" {
  value     = acme_registration.main.account_key_pem
  sensitive = true
}

output "registration_email_address" {
  value = acme_registration.main.email_address
}
