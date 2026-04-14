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

variable "image_litellm" {
  type    = string
  default = "ghcr.io/berriai/litellm:main-latest"
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
    "kimi-k2.5" = {
      model_id = "moonshotai.kimi-k2.5"
    }
    "glm-5" = {
      model_id = "zai.glm-5"
    }
    "deepseek-v3.2" = {
      model_id = "deepseek.v3.2"
    }
    "qwen3-coder-480b" = {
      model_id = "qwen.qwen3-coder-480b-a35b-v1:0"
    }
    "qwen3-235b" = {
      model_id = "qwen.qwen3-235b-a22b-2507-v1:0"
    }
    "llama4-maverick" = {
      model_id   = "us.meta.llama4-maverick-17b-instruct-v1:0"
      max_tokens = 32000
    }
  }
}

locals {
  nextcloud_image = "${var.registry_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}/nextcloud:latest"
}
