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
  type        = string
  description = "Headscale control-plane FQDN; used as --login-server"
}

variable "tailnet_hostname" {
  type        = string
  default     = "headscale-host"
  description = "Hostname advertised to the tailnet (MagicDNS label)"
}

variable "preauth_key" {
  type      = string
  sensitive = true
}
