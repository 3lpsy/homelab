# Shared

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
