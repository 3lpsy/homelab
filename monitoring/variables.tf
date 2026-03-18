variable "vault_root_token" {
  type = string
}

variable "headscale_subdomain" {
  type    = string
  default = "hs"
}

variable "headscale_magic_domain" {
  type = string
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

variable "acme_server_url" {
  type    = string
  default = "https://acme-v02.api.letsencrypt.org/directory"
}

# --- Grafana -----------------------------------------------------------------

variable "grafana_domain" {
  type    = string
  default = "grafana"
}

variable "grafana_admin_user" {
  type    = string
  default = "admin"
}

variable "openwrt_domain" {
  type        = string
  default = "openwrt"
}


# --- Prometheus --------------------------------------------------------------

variable "prometheus_retention" {
  type    = string
  default = "30d"
}

variable "prometheus_storage_size" {
  type    = string
  default = "20Gi"
}

variable "grafana_storage_size" {
  type    = string
  default = "5Gi"
}
