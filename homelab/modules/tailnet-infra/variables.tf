
# pub key contents
variable "headscale_server_domain" {
  type = string
}
variable "api_key" {
  type      = string
  sensitive = true
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
