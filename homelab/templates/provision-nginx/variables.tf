
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
variable "server_domain" {
  type = string
}
variable "proxy_port" {
  type = string
}
variable "proxy_proto" {
  type = string
}
variable "nginx_user" {
  type = string
}

variable "proxy_ssl_verify" {
  description = "Set to 'off' to disable SSL verification for backend, empty string to omit"
  type        = string
  default     = ""
}

variable "listen_prefix" {
  description = "Listen prefix, requires colon"
  type        = string
  default     = ""
}
