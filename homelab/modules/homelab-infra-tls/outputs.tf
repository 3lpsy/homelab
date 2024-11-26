

output "account_key_pem" {
  value     = acme_registration.main.account_key_pem
  sensitive = true
}
