
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
variable "headscale_version" {
  type    = string
  default = "0.23.0"
}
