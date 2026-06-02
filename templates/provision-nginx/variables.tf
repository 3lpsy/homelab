

variable "server_ip" {
  type = string
}
variable "ssh_user" {
  type = string
}
variable "ssh_priv_key" {
  type = string
}

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

variable "nginx_logging_block" {
  description = "Pre-rendered http{}-level logging block (log_format + map + access_log + error_log). Render `data/nginx/_logging.conf.tpl` and pass the result; defaults reproduce the prior plain-text combined-format behavior writing to /var/log/nginx/."
  type        = string
  default     = ""
}
