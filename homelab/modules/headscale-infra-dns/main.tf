resource "aws_route53_zone" "server" {
  name = var.headscale_server_domain
  tags = {
    Purpose = "headscale-server"
  }
}

resource "aws_route53_zone" "magic" {
  name = var.headscale_magic_domain
  tags = {
    Purpose = "headscale-magic"
  }
}

resource "aws_route53_record" "server" {
  zone_id = aws_route53_zone.server.zone_id
  name    = "${var.headscale_subdomain}.${var.headscale_server_domain}"
  type    = "A"
  ttl     = 60
  records = [var.headscale_server_ip]
}
