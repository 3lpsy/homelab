# Scoped AWS identity for the in-cluster TLS-rotation worker.
#
# Shape: long-lived IAM user + access key whose only permission is
# sts:AssumeRole into a role that holds the actual Route53 DNS-01 perms.
# Worker (data/images/tls-rotator) runs lego against the assumed-role's
# temporary STS creds, so the long-lived key never directly touches DNS.
#
# Permissions follow the lego Route53 provider's documented minimum:
#   - List* on `*` (zone discovery has no resource-level scoping)
#   - ChangeResourceRecordSets / ListResourceRecordSets scoped to the three
#     hosted zones we actually own
#   - GetChange on `*` (change IDs are global)

resource "aws_iam_user" "tls_rotator" {
  name = "tls-rotator"
}

resource "aws_iam_access_key" "tls_rotator" {
  user = aws_iam_user.tls_rotator.name
}

resource "aws_iam_user_policy" "tls_rotator_assume" {
  name = "tls-rotator-assume"
  user = aws_iam_user.tls_rotator.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = aws_iam_role.tls_rotator.arn
      }
    ]
  })
}

resource "aws_iam_role" "tls_rotator" {
  name = "tls-rotator"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = aws_iam_user.tls_rotator.arn }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "tls_rotator_route53" {
  name = "tls-rotator-route53"
  role = aws_iam_role.tls_rotator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DiscoverZones"
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones", "route53:ListHostedZonesByName"]
        Resource = "*"
      },
      {
        Sid    = "MutateOwnedZones"
        Effect = "Allow"
        Action = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
        Resource = [
          "arn:aws:route53:::hostedzone/${data.terraform_remote_state.homelab.outputs.route53_server_zone_id}",
          "arn:aws:route53:::hostedzone/${data.terraform_remote_state.homelab.outputs.route53_magic_zone_id}",
          "arn:aws:route53:::hostedzone/${data.terraform_remote_state.homelab.outputs.route53_magic_root_zone_id}",
        ]
      },
      {
        Sid      = "PollChangeStatus"
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "arn:aws:route53:::change/*"
      }
    ]
  })
}

resource "vault_kv_secret_v2" "tls_rotator_aws" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "tls-rotator/aws"
  data_json = jsonencode({
    aws_access_key_id     = aws_iam_access_key.tls_rotator.id
    aws_secret_access_key = aws_iam_access_key.tls_rotator.secret
    aws_region            = var.aws_region
    role_arn              = aws_iam_role.tls_rotator.arn
  })
}
