# AWS SES outbound mail for the homelab. Sends from
# <ses_mail_subdomain>.<headscale_magic_domain> (or any sub-domain you
# point services at). Provides:
#   - Verified SES domain identity (DNS TXT proof)
#   - DKIM signing (3x CNAME for selector tokens)
#   - SPF + DMARC TXT
#   - Custom MAIL FROM domain (bounces.<mail-domain>) so bounce paths
#     align with SPF and don't get tagged "via amazonses.com" in clients
#   - IAM user + access key whose v4-derived SMTP password is exported
#     via outputs.tf for downstream deployments to consume via remote_state
#
# Sandbox caveat: new SES domains start in sandbox mode (can only send
# *to* verified addresses). To send to arbitrary recipients (Gmail,
# ProtonMail, etc.) you need to request SES production access — one-time
# AWS support ticket, usually approved within a day. Not TF-able.

locals {
  ses_mail_domain         = "${var.ses_mail_subdomain}.${var.headscale_magic_domain}"
  ses_mail_from_domain    = "bounces.${local.ses_mail_domain}"
  ses_dmarc_record_name   = "_dmarc.${local.ses_mail_domain}"
  ses_verify_record_name  = "_amazonses.${local.ses_mail_domain}"
}

# ---- Domain identity + DNS verification ------------------------------------

resource "aws_ses_domain_identity" "mail" {
  domain = local.ses_mail_domain
}

resource "aws_route53_record" "ses_domain_verification" {
  zone_id = module.headscale-infra-dns.magic_root_zone_id
  name    = local.ses_verify_record_name
  type    = "TXT"
  ttl     = 600
  records = [aws_ses_domain_identity.mail.verification_token]
}

resource "aws_ses_domain_identity_verification" "mail" {
  domain = aws_ses_domain_identity.mail.id

  depends_on = [aws_route53_record.ses_domain_verification]
}

# ---- DKIM ------------------------------------------------------------------

resource "aws_ses_domain_dkim" "mail" {
  domain = aws_ses_domain_identity.mail.domain
}

resource "aws_route53_record" "ses_dkim" {
  count   = 3
  zone_id = module.headscale-infra-dns.magic_root_zone_id
  name    = "${aws_ses_domain_dkim.mail.dkim_tokens[count.index]}._domainkey.${local.ses_mail_domain}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_ses_domain_dkim.mail.dkim_tokens[count.index]}.dkim.amazonses.com"]
}

# ---- SPF + DMARC for the mail domain --------------------------------------

resource "aws_route53_record" "ses_spf" {
  zone_id = module.headscale-infra-dns.magic_root_zone_id
  name    = local.ses_mail_domain
  type    = "TXT"
  ttl     = 600
  records = ["v=spf1 include:amazonses.com -all"]
}

resource "aws_route53_record" "ses_dmarc" {
  zone_id = module.headscale-infra-dns.magic_root_zone_id
  name    = local.ses_dmarc_record_name
  type    = "TXT"
  ttl     = 600
  records = ["v=DMARC1; p=quarantine; rua=mailto:dmarc@${var.headscale_magic_domain}; ruf=mailto:dmarc@${var.headscale_magic_domain}; fo=1; adkim=r; aspf=r"]
}

# ---- Custom MAIL FROM (bounces.<mail-domain>) -----------------------------
# Without this, bounces come through ses-bounces.amazonses.com — clients
# show "via amazonses.com" and SPF doesn't fully align.

resource "aws_ses_domain_mail_from" "mail" {
  domain           = aws_ses_domain_identity.mail.domain
  mail_from_domain = local.ses_mail_from_domain
}

resource "aws_route53_record" "ses_mail_from_spf" {
  zone_id = module.headscale-infra-dns.magic_root_zone_id
  name    = local.ses_mail_from_domain
  type    = "TXT"
  ttl     = 600
  records = ["v=spf1 include:amazonses.com -all"]
}

resource "aws_route53_record" "ses_mail_from_mx" {
  zone_id = module.headscale-infra-dns.magic_root_zone_id
  name    = local.ses_mail_from_domain
  type    = "MX"
  ttl     = 600
  records = ["10 feedback-smtp.${var.aws_region}.amazonses.com"]
}

# ---- IAM user + SMTP credentials ------------------------------------------
# AWS provider derives the v4 SMTP password from the access key's secret
# automatically — no client-side HMAC needed.

resource "aws_iam_user" "ses_smtp" {
  name = "homelab-ses-smtp"
  path = "/system/"
  tags = {
    Purpose = "SES outbound SMTP for homelab services"
  }
}

data "aws_iam_policy_document" "ses_send" {
  statement {
    sid     = "AllowSESSend"
    effect  = "Allow"
    actions = [
      "ses:SendRawEmail",
      "ses:SendEmail",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_user_policy" "ses_smtp" {
  name   = "homelab-ses-send"
  user   = aws_iam_user.ses_smtp.name
  policy = data.aws_iam_policy_document.ses_send.json
}

resource "aws_iam_access_key" "ses_smtp" {
  user = aws_iam_user.ses_smtp.name
}
