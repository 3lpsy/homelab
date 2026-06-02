
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

output "server_zone_id" {
  value = aws_route53_zone.server.zone_id
}

output "magic_zone_id" {
  value = aws_route53_zone.magic.zone_id
}

output "magic_root_zone_id" {
  value = aws_route53_zone.magic_root.zone_id
}
