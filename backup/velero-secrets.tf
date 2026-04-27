# Velero pod reads AWS credentials from this Secret's `cloud` key. The chart
# is told to use it via `credentials.existingSecret = "velero-aws-creds"` in
# velero.tf. Format is the AWS shared-credentials INI file the AWS SDK
# auto-detects when AWS_SHARED_CREDENTIALS_FILE points at it.
resource "kubernetes_secret" "velero_aws_creds" {
  metadata {
    name      = "velero-aws-creds"
    namespace = kubernetes_namespace.velero.metadata[0].name
  }

  type = "Opaque"

  data = {
    cloud = <<-EOT
      [default]
      aws_access_key_id=${data.terraform_remote_state.homelab.outputs.backup_iam_keys["velero"].access_key_id}
      aws_secret_access_key=${data.terraform_remote_state.homelab.outputs.backup_iam_keys["velero"].secret_access_key}
    EOT
  }
}
