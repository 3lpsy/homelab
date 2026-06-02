resource "aws_route53_zone" "server" {
  name = var.headscale_server_domain
  tags = {
    Purpose = "headscale-server"
  }
}
resource "aws_route53_record" "server" {
  zone_id = aws_route53_zone.server.zone_id
  name    = "${var.headscale_subdomain}.${var.headscale_server_domain}"
  type    = "A"
  ttl     = 60
  records = [var.headscale_server_ip]
}

resource "aws_route53_zone" "magic_root" {
  name = var.headscale_magic_domain
  tags = {
    Purpose = "headscale-magic-root"
  }
}

resource "aws_route53_zone" "magic" {
  name = "${var.headscale_subdomain}.${var.headscale_magic_domain}"
  tags = {
    Purpose = "headscale-magic"
  }
}

resource "aws_route53_record" "magic_root_ns" {
  zone_id = aws_route53_zone.magic_root.zone_id
  name    = "${var.headscale_subdomain}.${var.headscale_magic_domain}"
  type    = "NS"
  ttl     = 30
  records = aws_route53_zone.magic.name_servers
}
