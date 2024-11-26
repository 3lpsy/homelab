
output "dns_domain" {
  value = "${var.headscale_subdomain}.${var.headscale_server_domain}"
}

output "headscale_name_servers" {
  value = aws_route53_zone.server.name_servers
}

output "magic_name_servers" {
  value = aws_route53_zone.magic.name_servers
}

output "magic_root_name_servers" {
  value = aws_route53_zone.magic_root.name_servers
}
