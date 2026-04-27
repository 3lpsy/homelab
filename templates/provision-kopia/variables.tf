variable "server_ip" {
  type = string
}

variable "ssh_user" {
  type = string
}

variable "ssh_priv_key" {
  type      = string
  sensitive = true
}

variable "bucket_name" {
  type = string
}

variable "bucket_region" {
  type = string
}

# S3 prefix for this client's kopia repo. Trailing slash required.
variable "prefix" {
  type = string
}

variable "aws_access_key_id" {
  type      = string
  sensitive = true
}

variable "aws_secret_access_key" {
  type      = string
  sensitive = true
}

variable "repo_password" {
  type      = string
  sensitive = true
}

variable "backup_paths" {
  type = list(string)
}

# Glob patterns excluded from snapshots, applied per-path via `kopia policy set
# <path> --add-ignore <pattern>` at repo init time. Survives across runs.
variable "exclude_globs" {
  type    = list(string)
  default = []
}

variable "on_calendar" {
  type    = string
  default = "daily"
}
