variable "state_dirs" {
  type = string
}

# Nginx logging — shared with services/. See data/nginx/_logging.conf.tpl
# for the JSON access-log shape. Zitadel sidecar uses these directly since
# vault-conf is a separate TF deployment from services/.
variable "nginx_log_level" {
  description = "error_log level for the zitadel nginx sidecar (debug|info|notice|warn|error|crit)."
  type        = string
  default     = "crit"
}

variable "nginx_access_log_enabled" {
  description = "Whether the zitadel nginx sidecar emits access logs."
  type        = bool
  default     = true
}

variable "nginx_log_static_assets" {
  description = "Log SPA static-asset GETs (js/css/svg/png/woff2/etc) for zitadel nginx. Default drops them."
  type        = bool
  default     = false
}

variable "vault_root_token" {
  type      = string
  sensitive = true
}

variable "headscale_magic_domain" {
  type = string
}

variable "headscale_subdomain" {
  type    = string
  default = "hs"
}

variable "vault_unseal_key" {
  type      = string
  sensitive = true
}

variable "kubeconfig_path" {
  type    = string
  default = "~/.config/kube/config"
}

# ---- ACME / AWS / DNS (consumed by templates/service-tls-vault) ------------

variable "acme_server_url" {
  type    = string
  default = "https://acme-v02.api.letsencrypt.org/directory"
}

variable "headscale_api_key" {
  type      = string
  sensitive = true
}

variable "aws_region" {
  type      = string
  default   = "us-east-1"
  sensitive = true
}

variable "aws_access_key" {
  type      = string
  sensitive = true
}

variable "aws_secret_key" {
  type      = string
  sensitive = true
}

variable "recursive_nameservers" {
  type    = list(string)
  default = ["9.9.9.9", "149.112.112.112"]
}

# ---- Zitadel ---------------------------------------------------------------

variable "zitadel_domain" {
  type    = string
  default = "oidc"
}

variable "zitadel_postgres_storage_size" {
  type    = string
  default = "5Gi"
}

# Real, deliverable email for the bootstrap admin (forwarded to your
# personal mailbox). Only consumed at FIRSTINSTANCE bootstrap; changing
# this var does NOT update the existing admin user — for that, edit in
# console (Users → admin → Email) or import + manage via zitadel_human_user.
variable "zitadel_admin_email_address" {
  type    = string
  default = ""
}

variable "image_zitadel" {
  type    = string
  default = "ghcr.io/zitadel/zitadel:latest"
}

# Zitadel v4 ships the login UI (Next.js) as a separate image. Its tag MUST
# match image_zitadel — login + api speak version-locked internal APIs.
variable "image_zitadel_login" {
  type    = string
  default = "ghcr.io/zitadel/zitadel-login:latest"
}

variable "image_zitadel_postgres" {
  type    = string
  default = "postgres:18-alpine"
}

variable "image_busybox" {
  type    = string
  default = "busybox:latest"
}

variable "image_nginx" {
  type    = string
  default = "nginx:alpine"
}

variable "image_tailscale" {
  type    = string
  default = "tailscale/tailscale:latest"
}

# pat-sync sidecar uses the vault CLI to push login-client.pat and
# tf-provider.pat from the bootstrap PVC into Vault KV.
variable "image_vault_cli" {
  type    = string
  default = "hashicorp/vault:1.18"
}
