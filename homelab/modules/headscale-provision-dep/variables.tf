

variable "server_ip" {
  type = string
}
variable "ssh_user" {
  type = string
}
variable "ssh_priv_key" {
  type = string
}

variable "headscale_version" {
  type    = string
  default = "0.27.1"
}
