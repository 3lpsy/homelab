# Velero CRDs are pure vendor schema — Velero ships them embedded in the
# binary and as separate YAML files at config/crd/v1/bases/ in the source
# repo. We fetch them at apply time via `data "http"` (native TF, no
# local-exec, no shell, no kubectl), pinned to the same tag as the runtime
# image so version drift is impossible.
#
# If Velero ever renames a file between versions, plan errors with
# "404 Not Found" pointing at the stale URL. Fix: update the filename in
# local.velero_crd_files (or rebase var.velero_image to a known-good tag).
#
# CRDs use the core apiextensions.k8s.io/v1 API which is always present, so
# planning these works on a fresh cluster. The plan-time chicken-and-egg
# only affects the *CR* resources (BSL, Schedule) in velero-resources.tf —
# they require the CRDs to exist on-cluster, hence the one-shot
# `apply -target=kubernetes_manifest.velero_crd` documented in CLAUDE.md.

locals {
  # Extract the tag from var.velero_image so the CRD fetch URL stays in
  # lockstep with the runtime image. e.g. "velero/velero:v1.14.0" -> "v1.14.0".
  velero_version = regex(":([^:]+)$", var.velero_image)[0]

  # Velero v1.14 splits CRDs across two paths in upstream:
  # - config/crd/v1/bases/         — main API (Backup, Restore, Schedule, ...)
  # - config/crd/v2alpha1/bases/   — newer kinds (DataDownload, DataUpload)
  # If a future Velero version reorganizes, plan errors with "404" on the
  # offending URL — fix the map below.
  velero_crd_v1_files = [
    "velero.io_backuprepositories.yaml",
    "velero.io_backups.yaml",
    "velero.io_backupstoragelocations.yaml",
    "velero.io_deletebackuprequests.yaml",
    "velero.io_downloadrequests.yaml",
    "velero.io_podvolumebackups.yaml",
    "velero.io_podvolumerestores.yaml",
    "velero.io_restores.yaml",
    "velero.io_schedules.yaml",
    "velero.io_serverstatusrequests.yaml",
    "velero.io_volumesnapshotlocations.yaml",
  ]

  velero_crd_v2alpha1_files = [
    "velero.io_datadownloads.yaml",
    "velero.io_datauploads.yaml",
  ]

  velero_crd_url_base = "https://raw.githubusercontent.com/vmware-tanzu/velero/${local.velero_version}/config/crd"

  velero_crd_urls = merge(
    { for f in local.velero_crd_v1_files : f =>
      "${local.velero_crd_url_base}/v1/bases/${f}" },
    { for f in local.velero_crd_v2alpha1_files : f =>
      "${local.velero_crd_url_base}/v2alpha1/bases/${f}" },
  )
}

data "http" "velero_crd" {
  for_each = local.velero_crd_urls
  url      = each.value

  request_headers = {
    Accept = "application/x-yaml"
  }
}

resource "kubernetes_manifest" "velero_crd" {
  for_each = data.http.velero_crd
  manifest = yamldecode(each.value.response_body)

  # Wait for the CRD to reach Established before TF returns. Downstream CRs
  # (BSL, Schedule) depend_on this resource, so by the time they apply the
  # CRD's API endpoint is fully registered.
  wait {
    condition {
      type   = "Established"
      status = "True"
    }
  }
}
