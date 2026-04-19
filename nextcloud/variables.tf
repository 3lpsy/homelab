variable "state_dirs" {
  type = string
}


variable "nextcloud_admin_user" {
  type    = string
  default = "admin"
}

variable "nextcloud_domain" {
  type    = string
  default = "nextcloud"
}

variable "collabora_domain" {
  type    = string
  default = "collabora"
}

variable "pihole_domain" {
  type    = string
  default = "pihole"
}

variable "vault_root_token" {
  type = string
}
variable "headscale_subdomain" {
  type    = string
  default = "hs"
}

variable "headscale_magic_domain" {
  type = string
}

variable "headscale_api_key" {
  type      = string
  sensitive = true
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

variable "radicale_domain" {
  type    = string
  default = "cal"
}

variable "registry_users" {
  description = "List of registry usernames"
  type        = list(string)
  default     = ["internal", "jim"]
}

variable "registry_domain" {
  type    = string
  default = "registry"
}

variable "immich_domain" {
  type    = string
  default = "immich"
}

# Container images

variable "image_busybox" {
  type    = string
  default = "busybox:latest"
}

variable "image_tailscale" {
  type    = string
  default = "tailscale/tailscale:latest"
}

variable "image_nginx" {
  type    = string
  default = "nginx:alpine"
}

variable "image_postgres" {
  type    = string
  default = "postgres:15-alpine"
}

variable "image_immich_postgres" {
  type    = string
  default = "ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0"
}

variable "image_redis" {
  type    = string
  default = "redis:7-alpine"
}

variable "image_valkey" {
  type    = string
  default = "docker.io/valkey/valkey:9"
}

variable "image_collabora" {
  type    = string
  default = "collabora/code:latest"
}

variable "image_immich_server" {
  type    = string
  default = "ghcr.io/immich-app/immich-server:release"
}

variable "image_immich_ml" {
  type    = string
  default = "ghcr.io/immich-app/immich-machine-learning:release"
}

variable "image_pihole" {
  type    = string
  default = "pihole/pihole:latest"
}

variable "image_registry" {
  type    = string
  default = "registry:2"
}

variable "image_radicale" {
  type    = string
  default = "ghcr.io/kozea/radicale:latest"
}

variable "image_python" {
  type    = string
  default = "python:3-alpine"
}

variable "image_wireguard" {
  type    = string
  default = "linuxserver/wireguard:latest"
}

variable "wireguard_config_dir" {
  description = "Path to directory containing WireGuard .conf files for ProtonVPN exit nodes"
  type        = string
}

variable "k8s_pod_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "k8s_service_cidr" {
  type    = string
  default = "10.43.0.0/16"
}

variable "litellm_domain" {
  type    = string
  default = "litellm"
}

variable "litellm_default_user_max_budget" {
  description = "Default max_budget (USD) applied to newly-created internal LiteLLM users"
  type        = number
  default     = 20
}

variable "image_litellm_postgres" {
  type    = string
  default = "pgvector/pgvector:pg15"
}

variable "image_litellm" {
  type    = string
  default = "ghcr.io/berriai/litellm:main-latest"
}

variable "bedrock_models" {
  description = "Map of alias name to Bedrock model config. `fake_stream = true` forces non-streaming upstream + synthesized SSE downstream — needed for non-Claude models on Bedrock that either don't support streaming or don't support tools during streaming (e.g. Llama 4 Maverick)."
  type = map(object({
    model_id    = string
    max_tokens  = optional(number)
    aws_region  = optional(string)
    fake_stream = optional(bool)
  }))
  default = {
    "claude-sonnet-4-20250514" = {
      model_id   = "us.anthropic.claude-sonnet-4-6"
      max_tokens = 16000
    }
    "claude-opus-4-20250514" = {
      model_id   = "us.anthropic.claude-opus-4-6-v1"
      max_tokens = 8000
    }
    "claude-haiku-4-5" = {
      model_id   = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
      max_tokens = 16000
    }
    "kimi-k2.5" = {
      model_id    = "moonshotai.kimi-k2.5"
      max_tokens  = 16000
      fake_stream = true
    }
    "glm-5" = {
      model_id    = "zai.glm-5"
      max_tokens  = 16000
      fake_stream = true
    }
    "deepseek-v3.2" = {
      model_id    = "deepseek.v3.2"
      max_tokens  = 8000
      fake_stream = true
    }
    "qwen3-coder-480b" = {
      model_id    = "qwen.qwen3-coder-480b-a35b-v1:0"
      aws_region  = "us-west-2"
      max_tokens  = 16000
      fake_stream = true
    }
    "qwen3-235b" = {
      model_id    = "qwen.qwen3-235b-a22b-2507-v1:0"
      aws_region  = "us-west-2"
      max_tokens  = 8000
      fake_stream = true
    }
    "llama4-maverick" = {
      model_id    = "us.meta.llama4-maverick-17b-instruct-v1:0"
      max_tokens  = 8000
      fake_stream = true
    }
  }
}

# Thunderbolt

variable "thunderbolt_domain" {
  type    = string
  default = "thunderbolt"
}

variable "thunderbolt_ref" {
  description = "git ref (branch, tag, commit) of thunderbird/thunderbolt to build"
  type        = string
  default     = "main"
}

variable "mcp_duckduckgo_domain" {
  type    = string
  default = "mcp-duckduckgo"
}

variable "searxng_domain" {
  type    = string
  default = "searxng"
}

variable "image_searxng" {
  type    = string
  default = "docker.io/searxng/searxng:latest"
}

variable "mcp_searxng_domain" {
  type    = string
  default = "mcp-searxng"
}

variable "mcp_searxng_api_key_count" {
  description = "How many random Bearer API keys to mint for the searxng MCP. Consumers read them from vault at mcp/mcp-searxng/auth."
  type        = number
  default     = 2
}

variable "image_thunderbolt_postgres" {
  type    = string
  default = "postgres:18-alpine"
}

variable "image_mongo" {
  type    = string
  default = "mongo:7.0"
}

variable "image_keycloak" {
  type    = string
  default = "quay.io/keycloak/keycloak:26.0"
}

variable "image_powersync" {
  type    = string
  default = "journeyapps/powersync-service:latest"
}

locals {
  nextcloud_image = "${var.registry_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}/nextcloud:latest"

  thunderbolt_registry          = "${var.registry_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  thunderbolt_frontend_image    = "${local.thunderbolt_registry}/thunderbolt-frontend:latest"
  thunderbolt_backend_image     = "${local.thunderbolt_registry}/thunderbolt-backend:latest"
  thunderbolt_fqdn              = "${var.thunderbolt_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  thunderbolt_public_url        = "https://${local.thunderbolt_fqdn}"
  thunderbolt_admin_email       = "thunderbolt@${var.headscale_subdomain}.${var.headscale_magic_domain}"

  mcp_duckduckgo_image = "${local.thunderbolt_registry}/mcp-duckduckgo:latest"
  mcp_duckduckgo_fqdn  = "${var.mcp_duckduckgo_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  mcp_duckduckgo_path  = "/public/mcp-duckduckgo"

  mcp_searxng_image = "${local.thunderbolt_registry}/mcp-searxng:latest"
  mcp_searxng_fqdn  = "${var.mcp_searxng_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  mcp_searxng_path  = "/public/mcp-searxng"

  exitnode_tinyproxy_image = "${local.thunderbolt_registry}/exitnode-tinyproxy:latest"

  searxng_ranker_image = "${local.thunderbolt_registry}/searxng-ranker:latest"
}
