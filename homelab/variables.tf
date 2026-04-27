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
variable "headscale_key_path" {
  type = string
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
  type = string
}
variable "ssh_pub_key_path" {
  type = string
}
variable "tailnet_users" {
  description = "Map of role keys to headscale usernames"
  type        = map(string)
  default = {
    personal_user           = "stargate"
    personal_laptop_user    = "ronin"
    nomad_server_user       = "orchard"
    mobile_user             = "mobile"
    registry_server_user    = "registry"
    registry_proxy_server_user = "registry-proxy"
    grafana_server_user     = "grafana"
    prometheus_user         = "prometheus"
    openwrt_user            = "openwrt"
    calendar_server_user    = "cal"
    tablet_user             = "tablet"
    deck_user               = "deck"
    devbox_user             = "devbox"
    exit_node_user          = "exitnode"
    tv_user                 = "tv"
    vault_server_user       = "vault-server"
    nextcloud_server_user   = "nextcloud"
    collabora_server_user   = "collabora"
    pihole_server_user      = "pihole"
    ntfy_server_user        = "ntfy"
    ollama_server_user      = "ollama"
    litellm_server_user     = "litellm"
    thunderbolt_server_user = "thunderbolt"
    mcp_user                = "mcp"
    builder_user            = "builder"
    searxng_server_user     = "searxng"
    log_server_user         = "openobserve"
    headscale_host_user     = "headscale-host"
    pod_provisioner_user    = "pod-provisioner"
    homeassist_server_user  = "homeassist"
    frigate_server_user     = "frigate"

  }
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


variable "bedrock_models" {
  description = "Map of alias name to Bedrock model config (id + optional max output tokens)"
  type = map(object({
    model_id   = string
    max_tokens = optional(number)
  }))
  default = {
    "claude-sonnet-4-20250514" = {
      model_id   = "us.anthropic.claude-sonnet-4-6"
      max_tokens = 32000
    }
    "claude-opus-4-20250514" = {
      model_id   = "us.anthropic.claude-opus-4-6-v1"
      max_tokens = 8000
    }
    "claude-haiku-4-5" = {
      model_id   = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
      max_tokens = 16000
    }
  }
}
