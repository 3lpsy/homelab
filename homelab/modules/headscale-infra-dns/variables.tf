# pub key contents
variable "headscale_server_domain" {
  type = string
}
variable "headscale_server_ip" {
  type = string
}

variable "headscale_magic_domain" {
  type = string
}
variable "headscale_subdomain" {
  type    = string
  default = "hs"
}
