# Backup IAM + per-client repo passwords. Reuses the existing aws_s3_bucket.main
# in module.headscale-infra. One bucket, one IAM user per client, scoped to its
# own prefix. Per-prefix isolation = per-host blast radius if a key leaks.
#
# Clients:
#   desktop   -> host-desktop/                 (kopia, set up out-of-band)
#   delphi    -> host-delphi/                  (kopia, provisioned by cluster)
#   headscale -> host-headscale/               (kopia, provisioned by homelab)
#   velero    -> cluster-${cluster_name}/velero/  (Velero BSL prefix in backup deployment)
#
# Repo passwords are random_password resources, output as sensitive values, and
# read by host provisioners over SSH (see templates/provision-kopia). They are
# not pushed to Vault — kopia clients run as host systemd daemons, not pods, so
# Vault CSI does not apply.
#
# Rotation: terraform apply -replace='random_password.backup_repo["delphi"]'

locals {
  backup_clients = {
    desktop   = "${var.backup_prefix_root}host-desktop/"
    delphi    = "${var.backup_prefix_root}host-delphi/"
    headscale = "${var.backup_prefix_root}host-headscale/"
    velero    = "${var.backup_prefix_root}cluster-${var.cluster_name}/velero/"
  }
}

# Bucket hardening on the existing aws_s3_bucket.main owned by headscale-infra.
# Versioning OFF: kopia is content-addressed and runs its own GC; bucket
# versioning would silently retain orphan blobs kopia cannot see.
resource "aws_s3_bucket_versioning" "backup" {
  bucket = module.headscale-infra.backup_bucket_name

  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket = module.headscale-infra.backup_bucket_name

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Server-side AES256. Belt and suspenders only — kopia/Velero already encrypt
# client-side; this just blunts S3-API-level mistakes (e.g. an accidentally
# public object).
resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = module.headscale-infra.backup_bucket_name

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_iam_user" "backup" {
  for_each = local.backup_clients
  name     = "homelab-backup-${each.key}"
  tags = {
    BackupClient = each.key
    BackupPrefix = each.value
  }
}

resource "aws_iam_access_key" "backup" {
  for_each = local.backup_clients
  user     = aws_iam_user.backup[each.key].name
}

resource "aws_iam_user_policy" "backup" {
  for_each = local.backup_clients
  name     = "homelab-backup-${each.key}"
  user     = aws_iam_user.backup[each.key].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListBucketPrefix"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = module.headscale-infra.backup_bucket_arn
        Condition = {
          StringLike = {
            "s3:prefix" = ["${each.value}*", each.value]
          }
        }
      },
      {
        Sid    = "ObjectAccessInPrefix"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "${module.headscale-infra.backup_bucket_arn}/${each.value}*"
      },
    ]
  })
}

resource "random_password" "backup_repo" {
  for_each = local.backup_clients
  length   = 48
  special  = false
}

# ─── Outputs ──────────────────────────────────────────────────────────────────
# Aggregate map outputs feed cluster + backup deployments via remote_state.
# Flat outputs are convenience hooks for the desktop runbook (terraform output -raw).
# All sensitive — surfaced only via `terraform output -json` after apply.

output "backup_bucket_name" {
  value = module.headscale-infra.backup_bucket_name
}

output "backup_bucket_region" {
  value     = var.aws_region
  sensitive = true
}

output "backup_iam_keys" {
  description = "Per-client AWS IAM access keys for the backup bucket"
  value = {
    for k, v in aws_iam_access_key.backup : k => {
      access_key_id     = v.id
      secret_access_key = v.secret
    }
  }
  sensitive = true
}

output "backup_repo_passwords" {
  description = "Per-client kopia repository passwords"
  value       = { for k, v in random_password.backup_repo : k => v.result }
  sensitive   = true
}

output "backup_prefixes" {
  description = "Per-client S3 prefix (within the shared bucket)"
  value       = local.backup_clients
}

# Flat conveniences for the desktop runbook (`terraform output -raw <name>`).
output "desktop_iam_access_key_id" {
  value     = aws_iam_access_key.backup["desktop"].id
  sensitive = true
}

output "desktop_iam_secret_key" {
  value     = aws_iam_access_key.backup["desktop"].secret
  sensitive = true
}

output "desktop_kopia_repo_password" {
  value     = random_password.backup_repo["desktop"].result
  sensitive = true
}

output "desktop_kopia_repo_prefix" {
  value = local.backup_clients["desktop"]
}
