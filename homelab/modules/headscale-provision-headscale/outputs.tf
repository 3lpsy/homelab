
output "encryption_pub_key_pem" {
  value = tls_private_key.encryption_key.public_key_pem
}

output "encryption_priv_key_pem" {
  value = tls_private_key.encryption_key.private_key_pem
}
