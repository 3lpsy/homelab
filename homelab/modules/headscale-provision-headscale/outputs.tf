output "headscale_server_domain" {
  value = var.headscale_server_domain
}
output "api_key" {
  value     = data.local_file.api_key.content
  sensitive = true

  depends_on = [null_resource.download_api_key]
}
