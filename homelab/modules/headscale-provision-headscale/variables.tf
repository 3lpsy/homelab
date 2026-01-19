
# pub key contents
variable "server_ip" {
  type = string
}
variable "ssh_user" {
  type = string
}
variable "ssh_priv_key_path" {
  type = string
}
# pub key contents
variable "headscale_server_domain" {
  type = string
}
# pub key contents
variable "headscale_magic_domain" {
  type = string
}
variable "headscale_port" {
  type    = string
  default = "8443"
}
variable "backup_bucket_name" {
  type = string
}

variable "personal_username" {
  type = string
}
variable "mobile_username" {
  type = string
}
variable "tablet_username" {
  type = string
}
variable "deck_username" {
  type = string
}
variable "devbox_username" {
  type = string
}
variable "nomad_server_username" {
  type = string
}
variable "vault_server_username" {
  type = string
}

variable "nextcloud_server_username" {
  type = string
}
