variable "state_dirs" {
  type = string
}


variable "grafana_domain" {
  type    = string
  default = "grafana"
}

variable "grafana_admin_user" {
  type    = string
  default = "admin"
}

variable "headscale_subdomain" {
  type    = string
  default = "hs"
}

variable "headscale_magic_domain" {
  type = string
}
