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
variable "headscale_server_domain" {
  type = string
}
variable "headscale_magic_domain" {
  type = string
}
variable "headscale_subdomain" {
  type    = string
  default = "hs"
}
variable "homelab_bucket_name" {
  type = string
}
variable "registration_email_address" {
  type = string
}
variable "ssh_priv_key_path" {
  type    = string
  default = "../ssh.pem"
}
variable "ssh_pub_key_path" {
  type    = string
  default = "../ssh.pem.pub"
}
variable "tailnet_personal_username" {
  type = string
}
variable "tailnet_nomad_server_username" {
  type = string
}
variable "tailnet_vault_server_username" {
  type    = string
  default = "vault-server"
}
variable "tailnet_mobile_username" {
  type    = string
  default = "mobile"
}
variable "tailnet_tablet_username" {
  type    = string
  default = "tablet"
}
variable "tailnet_deck_username" {
  type    = string
  default = "deck"
}
variable "tailnet_devbox_username" {
  type    = string
  default = "devbox"
}
variable "nomad_host_name" {
  type = string
}
variable "nomad_ssh_user" {
  type = string
}

variable "nomad_server_ip" {
  type = string
}

variable "headscale_api_key" {
  type    = string
  default = ""
}

variable "acme_server_url" {
  type    = string
  default = "https://acme-v02.api.letsencrypt.org/directory"
}
variable "recursive_nameservers" {
  type    = list(string)
  default = ["9.9.9.9", "149.112.112.112"]
}
