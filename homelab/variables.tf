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
# Used as a label in the cluster's backup prefix; must match
# cluster.var.node_host_name so the two deployments agree on naming.
variable "cluster_name" {
  type    = string
  default = "delphi"
}
# Parent prefix for every kopia repo inside the shared backup bucket.
# Isolates them from terraform.sh state files (s3://$BUCKET/$dep/...) and the
# legacy headscale/<ts>.age blobs that already live at the bucket root.
# Trailing slash required.
variable "backup_prefix_root" {
  type    = string
  default = "backup/repos/"
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
    music_server_user       = "music"
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
    searxng_server_user     = "searxng"
    log_server_user         = "openobserve"
    headscale_host_user     = "headscale-host"
    homeassist_server_user  = "homeassist"
    frigate_server_user     = "frigate"
    jellyfin_server_user    = "media"
    syncthing_server_user   = "syncthing"
    ingest_server_user      = "ingest"

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
