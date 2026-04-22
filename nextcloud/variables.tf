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

variable "llm_models" {
  description = "Map of alias name to LiteLLM model config. `provider` selects upstream: `bedrock` (AWS IAM creds, optional per-model aws_region) or `deepinfra` (DEEPINFRA_API_KEY)."
  type = map(object({
    provider                    = string
    model_id                    = string
    max_tokens                  = optional(number)
    aws_region                  = optional(string)
    input_cost_per_token        = optional(number)
    output_cost_per_token       = optional(number)
    cache_read_input_token_cost = optional(number)
  }))
  default = {
    # ============================================================
    # FLAGSHIP — 100B-class MoE, fits 2×R9700 at 4-bit
    # ============================================================
    "flagship-gpt-oss-120b" = {
      provider              = "deepinfra"
      model_id              = "openai/gpt-oss-120b"
      max_tokens            = 16000
      input_cost_per_token  = 3.9e-8
      output_cost_per_token = 1.9e-7
    }

    # ============================================================
    # AGENTIC — 80-106B MoE, different architectural strengths
    # ============================================================
    "agent-glm-4.5-air" = {
      provider              = "deepinfra"
      model_id              = "zai-org/GLM-4.5-Air"
      max_tokens            = 16000
      input_cost_per_token  = 2e-7
      output_cost_per_token = 1.1e-6
    }

    "agent-qwen3-next-80b" = {
      provider              = "deepinfra"
      model_id              = "Qwen/Qwen3-Next-80B-A3B-Instruct"
      max_tokens            = 32000 # long context shines here
      input_cost_per_token  = 9e-8
      output_cost_per_token = 1.1e-6
    }

    # ============================================================
    # CODING — 30B-A3B class, single-card friendly, A/B pair
    # ============================================================
    "coding-qwen-3.6-35b-a3b" = {
      provider              = "deepinfra"
      model_id              = "Qwen/Qwen3.6-35B-A3B"
      max_tokens            = 16000
      input_cost_per_token  = 2e-7
      output_cost_per_token = 1e-6
    }

    "coding-glm-4.7-flash" = {
      provider              = "deepinfra"
      model_id              = "zai-org/GLM-4.7-Flash"
      max_tokens            = 16000
      input_cost_per_token  = 6e-8
      output_cost_per_token = 4e-7
    }

    # ============================================================
    # DEFAULT — dense multimodal, runs on single R9700
    # ============================================================
    "default-gemma-4-31b" = {
      provider              = "deepinfra"
      model_id              = "google/gemma-4-31B-it"
      max_tokens            = 16000
      input_cost_per_token  = 1.3e-7
      output_cost_per_token = 3.8e-7
    }

    # ============================================================
    # BULK/FAST — small, cheap, high-throughput
    # ============================================================
    "default-qwen-3.5-4b" = {
      provider              = "deepinfra"
      model_id              = "Qwen/Qwen3.5-4B"
      max_tokens            = 8000
      input_cost_per_token  = 3e-8
      output_cost_per_token = 1.5e-7
    }

    "bulk-qwen-3.5-2b" = {
      provider              = "deepinfra"
      model_id              = "Qwen/Qwen3.5-2B"
      max_tokens            = 4000
      input_cost_per_token  = 2e-8
      output_cost_per_token = 1e-7
    }

    "bulk-gpt-oss-20b" = {
      provider              = "deepinfra"
      model_id              = "openai/gpt-oss-20b"
      max_tokens            = 8000
      input_cost_per_token  = 3e-8
      output_cost_per_token = 1.4e-7
    }

    "reasoning-qwen-3.5-27b" = {
      provider              = "deepinfra"
      model_id              = "Qwen/Qwen3.5-27B"
      max_tokens            = 8000
      input_cost_per_token  = 2.6e-7
      output_cost_per_token = 2.6e-6
    }
  }
}

variable "deepinfra_api_key" {
  type      = string
  sensitive = true
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

variable "mcp_filesystem_log_level" {
  description = "LOG_LEVEL for the filesystem MCP server (debug / info / warning / error)."
  type        = string
  default     = "info"
}

variable "mcp_memory_log_level" {
  description = "LOG_LEVEL for the memory MCP server (debug / info / warning / error)."
  type        = string
  default     = "info"
}

variable "mcp_searxng_log_level" {
  description = "LOG_LEVEL for the searxng MCP server (debug / info / warning / error)."
  type        = string
  default     = "info"
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

variable "mcp_shared_domain" {
  type    = string
  default = "mcp-shared"
}

variable "mcp_api_key_users" {
  description = "Named consumers of the shared MCP auth pool. One random Bearer key is minted per name and stored at vault `mcp/auth` under `api_key_<name>`, plus the aggregate `api_keys_csv` that every MCP pod reads."
  type        = list(string)
  default     = ["thunderbolt", "litellm"]
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

  thunderbolt_registry       = "${var.registry_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  thunderbolt_frontend_image = "${local.thunderbolt_registry}/thunderbolt-frontend:latest"
  thunderbolt_backend_image  = "${local.thunderbolt_registry}/thunderbolt-backend:latest"
  thunderbolt_fqdn           = "${var.thunderbolt_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  thunderbolt_public_url     = "https://${local.thunderbolt_fqdn}"
  thunderbolt_admin_email    = "thunderbolt@${var.headscale_subdomain}.${var.headscale_magic_domain}"

  mcp_searxng_image    = "${local.thunderbolt_registry}/mcp-searxng:latest"
  mcp_filesystem_image = "${local.thunderbolt_registry}/mcp-filesystem:latest"
  mcp_memory_image     = "${local.thunderbolt_registry}/mcp-memory:latest"

  mcp_shared_fqdn = "${var.mcp_shared_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"

  # Backends the shared nginx proxies to. `upstream_path` is where each
  # backend mounts its MCP endpoint. All three fastmcp servers mount at
  # `/`, so nginx just strips the `/mcp-<name>/` prefix and passes the
  # rest through — clients address every backend as the bare
  # `/mcp-<name>/` URL.
  mcp_backend_services = {
    "mcp-filesystem" = { upstream_path = "/" }
    "mcp-memory"     = { upstream_path = "/" }
    "mcp-searxng"    = { upstream_path = "/" }
  }

  exitnode_tinyproxy_image = "${local.thunderbolt_registry}/exitnode-tinyproxy:latest"

  searxng_ranker_image = "${local.thunderbolt_registry}/searxng-ranker:latest"
}
