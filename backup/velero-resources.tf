# Velero CRs: BackupStorageLocation and Schedule. Both are velero.io/v1 kinds
# whose CRDs come from velero-crds.tf. Plan-time validation requires the CRDs
# to exist on-cluster — see data/velero/README.md for the one-shot bootstrap
# (`apply -target=kubernetes_manifest.velero_crd`) on a fresh cluster.

resource "kubernetes_manifest" "velero_bsl" {
  manifest = {
    apiVersion = "velero.io/v1"
    kind       = "BackupStorageLocation"
    metadata = {
      name      = "default"
      namespace = kubernetes_namespace.velero.metadata[0].name
    }
    spec = {
      provider = "aws"
      default  = true

      objectStorage = {
        bucket = data.terraform_remote_state.homelab.outputs.backup_bucket_name
        # Velero appends "/" itself; strip the trailing slash from the prefixes
        # map value so the rendered S3 key matches the IAM policy's prefix.
        prefix = trimsuffix(data.terraform_remote_state.homelab.outputs.backup_prefixes["velero"], "/")
      }

      config = {
        region = data.terraform_remote_state.homelab.outputs.backup_bucket_region
      }

      credential = {
        name = kubernetes_secret.velero_aws_creds.metadata[0].name
        key  = "cloud"
      }
    }
  }

  depends_on = [
    kubernetes_manifest.velero_crd,
    kubernetes_deployment.velero,
  ]
}

resource "kubernetes_manifest" "velero_schedule_nightly" {
  manifest = {
    apiVersion = "velero.io/v1"
    kind       = "Schedule"
    metadata = {
      name      = "nightly"
      namespace = kubernetes_namespace.velero.metadata[0].name
    }
    spec = {
      schedule = var.velero_schedule_cron
      template = {
        ttl                      = var.velero_backup_ttl
        defaultVolumesToFsBackup = true
        # Vault CSI is the source of truth for Secret values — etcd holds only
        # stubs. Restoring stubs would be discarded by the next CSI reconcile,
        # so excluding the kind keeps the manifest tarball clean.
        excludedResources = ["secrets"]
        # No includedNamespaces -> all namespaces.
      }
    }
  }

  depends_on = [
    kubernetes_manifest.velero_crd,
    kubernetes_deployment.velero,
  ]
}
