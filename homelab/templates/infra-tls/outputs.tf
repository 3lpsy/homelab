

output "certificate_pem" {
  value     = acme_certificate.main.certificate_pem
  sensitive = true
}
output "issuer_pem" {
  value     = acme_certificate.main.issuer_pem
  sensitive = true
}
output "privkey_pem" {
  value     = acme_certificate.main.private_key_pem
  sensitive = true
}
output "fullchain_pem" {
  value     = "${acme_certificate.main.certificate_pem}${acme_certificate.main.issuer_pem}"
  sensitive = true
}
output "certificate_domain" {
  value = acme_certificate.main.certificate_domain
}
