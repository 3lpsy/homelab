# Velero CRD source

Velero's CustomResourceDefinitions are pure vendor schema — they ship embedded
in the velero binary AND as separate YAML files in the upstream source repo.
This homelab fetches them at apply time over HTTPS, pinned to the same Velero
tag as the controller image. **No vendored YAML in this directory, no manual
`velero install --crds-only` step.**

## How it works

`backup/velero-crds.tf` declares a `data "http"` per CRD, pointing at:
```
https://raw.githubusercontent.com/vmware-tanzu/velero/${tag}/config/crd/v1/bases/<file>.yaml
```

Tag is derived from `var.velero_image` via `regex()` — bumping the image tag
also bumps the CRD source. Each fetched body is `yamldecode`d and applied
via `kubernetes_manifest`.

## Bumping Velero

1. Update `var.velero_image` in `backup/variables.tf` (e.g. `velero/velero:v1.14.0` → `v1.15.0`).
2. Update `var.velero_aws_plugin_image` in lockstep (compat matrix at
   https://github.com/vmware-tanzu/velero-plugin-for-aws#compatibility).
3. `./terraform.sh backup apply`.

If Velero ever renames or splits a CRD file, plan fails with "404 Not Found"
pointing at the stale URL. Fix: edit `local.velero_crd_files` in
`backup/velero-crds.tf` to match the new filenames. List of expected files
lives in that local block.

## First-apply chicken-and-egg

CRs in `backup/velero-resources.tf` (BSL, Schedule) are `kubernetes_manifest`
resources of `kind: BackupStorageLocation` / `kind: Schedule`, which require
the CRDs to exist on-cluster *at plan time* (TF reads the schema to validate
the body). Fresh-cluster bootstrap therefore needs a one-shot CRD-only apply:

```bash
./terraform.sh backup init
./terraform.sh backup apply -target=kubernetes_manifest.velero_crd
./terraform.sh backup apply
```

Subsequent applies are single-step because the CRDs are already on-cluster.
