
output "dns_domain" {
  value = "${var.headscale_subdomain}.${var.headscale_server_domain}"
}
