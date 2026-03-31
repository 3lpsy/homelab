

variable "server_ip" {
  type = string
}
variable "ssh_user" {
  type = string
}
variable "ssh_priv_key_path" {
  type = string
}

variable "headscale_server_domain" {
  type = string
}
variable "headscale_key_path" {
  type = string
}

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
variable "tailnet_users" {
  description = "Map of role keys to headscale usernames"
  type        = map(string)
}
