variable "state_dirs" {
  type = string
}

variable "ssh_priv_key_path" {
  type = string
}

variable "node_host_name" {
  type = string
}

variable "node_ssh_user" {
  type = string
}

variable "node_server_ip" {
  type = string
}

variable "headscale_api_key" {
  type    = string
  default = ""
}

variable "headscale_magic_domain" {
  type = string
}

variable "headscale_subdomain" {
  type    = string
  default = "hs"
}

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

variable "recursive_nameservers" {
  type    = list(string)
  default = ["9.9.9.9", "149.112.112.112"]
}

variable "acme_server_url" {
  type    = string
  default = "https://acme-v02.api.letsencrypt.org/directory"
}
