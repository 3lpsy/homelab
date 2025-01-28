variable "tailnet_auth_key" {
  type      = string
  sensitive = true
}
variable "host" {
  type = string
}
variable "ssh_user" {
  type = string
}
variable "ssh_priv_key" {
  type = string
}
variable "headscale_tag" {
  type = string
}
variable "headscale_server_domain" {
  type = string
}

variable "headscale_magic_domain" {
  type = string
}
variable "hostname" {
  type = string
}
