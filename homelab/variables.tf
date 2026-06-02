variable "aws_region" {
  type    = string
  default = "us-east-1"
}

# Headscale EC2 host nginx logging. Writes JSON access logs to
# /var/log/nginx/access.log (tailed by data/otel/headscale-collector-
# config.yaml.tpl). Same JSON shape as the in-cluster nginx sidecars
# (see data/nginx/_logging.conf.tpl). The oidc-public vhost inherits.
variable "headscale_nginx_log_level" {
  description = "error_log level for the headscale EC2 host nginx (debug|info|notice|warn|error|crit). nginx default is `error`; we keep that to preserve historical behavior."
  type        = string
  default     = "error"
}

variable "headscale_nginx_access_log_enabled" {
  description = "Whether the headscale EC2 host nginx emits access logs."
  type        = bool
  default     = true
}

variable "headscale_nginx_log_static_assets" {
  description = "Log SPA static-asset GETs on the headscale EC2 host nginx. Default drops them."
  type        = bool
  default     = false
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
    provisioner_user           = "provisioner"
    personal_laptop_user       = "ronin"
    nomad_server_user          = "orchard"
    registry_server_user       = "registry"
    registry_proxy_server_user = "registry-proxy"
    grafana_server_user        = "grafana"
    prometheus_user            = "prometheus"
    openwrt_user               = "openwrt"
    calendar_server_user       = "cal"
    music_server_user          = "music"
    devbox_user                = "devbox"
    exit_node_user             = "exitnode"
    tv_user                    = "tv"
    vault_server_user          = "vault-server"
    nextcloud_server_user      = "nextcloud"
    collabora_server_user      = "collabora"
    pihole_server_user         = "pihole"
    ntfy_server_user           = "ntfy"
    ollama_server_user         = "ollama"
    litellm_server_user        = "litellm"
    llm_server_user            = "llm"
    thunderbolt_server_user    = "thunderbolt"
    mcp_user                   = "mcp"
    searxng_server_user        = "searxng"
    log_server_user            = "openobserve"
    headscale_host_user        = "headscale-host"
    homeassist_server_user     = "homeassist"
    frigate_server_user        = "frigate"
    jellyfin_server_user       = "media"
    syncthing_server_user      = "syncthing"
    ingest_server_user         = "ingest"
    podcast_server_user        = "podcast"
    oidc_server_user           = "oidc"
    headlamp_server_user       = "headlamp"
    homepage_server_user       = "homepage"
    opencode_server_user       = "opencode"
    pdf_server_user            = "pdf"
    git_server_user            = "git"
    qbt_server_user            = "qbt"

  }
}

variable "headscale_api_key" {
  type    = string
  default = ""
}

variable "personal_user_oidc_name" {
  description = "Headscale username assigned to the personal user when signing in via Zitadel OIDC. Empty = OIDC not in use. After first OIDC login, find via `headscale users list -o json | jq '.[].name'` and set TF_VAR_personal_user_oidc_name in .env. Defines `group:personal` (and the `tag:personal-roaming` tag owner). When empty, the group + tag are omitted entirely and any ACL rule referencing them is filtered out."
  type        = string
  default     = ""
}

variable "partner_user_oidc_name" {
  description = "Headscale username for the partner OIDC identity. Same shape as personal_user_oidc_name — set in .env once the partner has a Zitadel account. Empty default keeps the group:partner-related ACL rules out of the policy until OIDC is actually wired up for them."
  type        = string
  default     = ""
}

variable "acme_server_url" {
  type    = string
  default = "https://acme-v02.api.letsencrypt.org/directory"
}
variable "recursive_nameservers" {
  type    = list(string)
  default = ["9.9.9.9", "149.112.112.112"]
}

# ---- AWS SES outbound mail (homelab/ses.tf) -------------------------------

variable "ses_mail_subdomain" {
  description = "Sub-domain under headscale_magic_domain used as the SES MAIL FROM identity. Default = 'mail' → mail.<magic_domain>."
  type        = string
  default     = "mail"
}


# ---- Public OIDC reverse proxy (homelab/oidc-proxy.tf) -------------------

variable "oidc_proxy_user" {
  description = "HTTP basic-auth username for the public OIDC reverse proxy on the headscale EC2. No default — set via .env (e.g. TF_VAR_oidc_proxy_user=homelab). Acts as a low-friction front gate before the Zitadel login UI itself."
  type        = string
  sensitive   = true
}

variable "oidc_proxy_password" {
  description = "HTTP basic-auth passphrase for the public OIDC reverse proxy. No default — set via .env. Stored on the EC2 as a bcrypt hash inside /etc/nginx/oidc-public.htpasswd; rotate by changing the var and reapplying."
  type        = string
  sensitive   = true
}

variable "zitadel_subdomain" {
  description = "Subdomain under headscale_subdomain.headscale_magic_domain that Zitadel serves on. Must match var.zitadel_domain in vault-conf (default 'oidc' there) so the issuer URL stays byte-identical for off-tailnet OIDC discovery."
  type        = string
  default     = "oidc"
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
