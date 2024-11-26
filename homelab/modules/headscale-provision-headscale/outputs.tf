
output "encryption_pub_key_pem" {
  value = tls_private_key.encryption_key.public_key_pem
}

output "encryption_priv_key_pem" {
  value = tls_private_key.encryption_key.private_key_pem
}
output "headscale_server_domain" {
  value = var.headscale_server_domain
}
output "api_key" {
  value      = data.local_file.api_key.content
  depends_on = [null_resource.download_api_key]
}
