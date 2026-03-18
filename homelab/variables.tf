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
variable "headscale_server_domain" {
  type = string
}
variable "headscale_magic_domain" {
  type = string
}
variable "headscale_subdomain" {
  type    = string
  default = "hs"
}
variable "homelab_bucket_name" {
  type = string
}
variable "registration_email_address" {
  type = string
}
variable "ssh_priv_key_path" {
  type    = string
  default = "../ssh.pem"
}
variable "ssh_pub_key_path" {
  type    = string
  default = "../ssh.pem.pub"
}
variable "tailnet_users" {
  description = "Map of role keys to headscale usernames"
  type        = map(string)
  default = {
    personal_user         = "stargate"
    nomad_server_user     = "orchard"
    mobile_user           = "mobile"
    registry_server_user  = "registry"
    grafana_server_user   = "grafana"
    prometheus_user       = "prometheus"
    openwrt_user          = "openwrt"
    calendar_server_user  = "cal"
    tablet_user           = "tablet"
    deck_user             = "deck"
    devbox_user           = "devbox"
    exit_node_user        = "exitnode"
    tv_user               = "tv"
    vault_server_user     = "vault-server"
    nextcloud_server_user = "nextcloud"
    collabora_server_user = "collabora"
    pihole_server_user    = "pihole"
  }
}

variable "nomad_host_name" {
  type = string
}

variable "nomad_ssh_user" {
  type = string
}

variable "nomad_server_ip" {
  type = string
}

variable "headscale_api_key" {
  type    = string
  default = ""
}

variable "acme_server_url" {
  type    = string
  default = "https://acme-v02.api.letsencrypt.org/directory"
}
variable "recursive_nameservers" {
  type    = list(string)
  default = ["9.9.9.9", "149.112.112.112"]
}
