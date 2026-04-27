variable "state_dirs" {
  type = string
}

variable "kubeconfig_path" {
  type = string
}

# Velero server + node-agent share the same image. Tried `gcr.io/velero-gcp`
# (referenced in Velero's Makefile) but it 403s anonymous pulls — appears to
# be a Velero-internal staging registry, not for public consumption. Public
# pulls go through docker.io only. Routes through registry-dockerio →
# (optional) exitnode-haproxy rotator to dodge Docker Hub's per-IP anon limit.
# Bump in lockstep with the CRD URLs in velero-crds.tf (schemas evolve across
# major versions).
variable "velero_image" {
  type    = string
  default = "velero/velero:v1.14.0"
}

# AWS object-store provider plugin.
# Compat matrix:
# https://github.com/vmware-tanzu/velero-plugin-for-aws#compatibility
variable "velero_aws_plugin_image" {
  type    = string
  default = "velero/velero-plugin-for-aws:v1.10.0"
}

variable "velero_schedule_cron" {
  type    = string
  default = "0 2 * * *"
}

# 30 days. Drives S3 cost. Velero deletes backups + their kopia content past TTL.
variable "velero_backup_ttl" {
  type    = string
  default = "720h0m0s"
}
