
# pub key contents
variable "server_ip" {
  type = string
}
variable "ssh_user" {
  type = string
}
variable "ssh_priv_key" {
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
