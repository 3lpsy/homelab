# IAM user used by the in-cluster Zitadel domain-verification Job (services/zitadel-org-domain.tf).
#
# The Job needs to write a one-shot TXT record under hs.magic (the
# headscale magic-root zone) to satisfy Zitadel's ValidateOrgDomain DNS
# challenge, then read back its propagation status. Scope is locked to a
# single hosted zone and three Route53 verbs — nothing else.
#
# Access key + secret are surfaced via sensitive outputs and copied into
# Vault by the vault-conf deployment, then mounted into the Job pod via
# the Vault CSI driver. They never appear in cluster ConfigMaps or logs.

resource "aws_iam_user" "zitadel_domain_verify" {
  name = "zitadel-domain-verify"
  path = "/service/"
  tags = {
    Purpose = "zitadel-org-domain-verification"
  }
}

resource "aws_iam_access_key" "zitadel_domain_verify" {
  user = aws_iam_user.zitadel_domain_verify.name
}

resource "aws_iam_user_policy" "zitadel_domain_verify" {
  name = "zitadel-domain-verify-r53"
  user = aws_iam_user.zitadel_domain_verify.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ZoneRecordWrite"
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
          "route53:GetHostedZone",
        ]
        Resource = "arn:aws:route53:::hostedzone/${module.headscale-infra-dns.magic_root_zone_id}"
      },
      {
        Sid      = "ChangeStatusRead"
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "arn:aws:route53:::change/*"
      },
    ]
  })
}

output "zitadel_domain_verify_aws_access_key_id" {
  description = "AWS access key id for the Zitadel domain-verify Job. Consumed by vault-conf to populate secret/zitadel/domain-verify."
  value       = aws_iam_access_key.zitadel_domain_verify.id
  sensitive   = true
}

output "zitadel_domain_verify_aws_secret_access_key" {
  description = "AWS secret access key for the Zitadel domain-verify Job. Consumed by vault-conf to populate secret/zitadel/domain-verify."
  value       = aws_iam_access_key.zitadel_domain_verify.secret
  sensitive   = true
}

output "zitadel_domain_verify_zone_id" {
  description = "Route53 hosted-zone id (headscale magic-root) the Zitadel domain-verify Job writes its TXT challenge into."
  value       = module.headscale-infra-dns.magic_root_zone_id
}
