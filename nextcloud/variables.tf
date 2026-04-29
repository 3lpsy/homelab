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

variable "exitnode_haproxy_domain" {
  type    = string
  default = "exitnode-haproxy"
}

variable "navidrome_domain" {
  type    = string
  default = "music"
}

variable "homeassist_domain" {
  type    = string
  default = "homeassist"
}

variable "homeassist_admin_user" {
  type    = string
  default = "admin"
}

variable "homeassist_time_zone" {
  type    = string
  default = "America/Chicago"
}

variable "homeassist_z2m_domain" {
  type    = string
  default = "z2m"
}

variable "homeassist_z2m_usb_device_path" {
  description = "Stable hostPath of the Zigbee coordinator's USB serial device on the K3s node. Empty until the dongle is plugged in. Find it with `ls -l /dev/serial/by-id/` and use the full `/dev/serial/by-id/usb-Nabu_Casa_Home_Assistant_Connect_ZBT-2_<serial>-if00` path so it survives reboots and re-enumeration."
  type        = string
  default     = ""
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

variable "registry_dockerio_domain" {
  type = string
  # Public hostname (under headscale_subdomain.headscale_magic_domain) for the
  # docker.io pull-through cache. Renamed from registry-proxy to leave room
  # for sibling mirrors (registry-quayio, registry-ghcr, ...). All mirrors
  # share the headscale "registry-proxy" user identity for ACL purposes; only
  # the per-pod TS_HOSTNAME differs.
  default = "registry-dockerio"
}

variable "registry_ghcrio_domain" {
  type        = string
  description = "Tailnet hostname for the ghcr.io pull-through cache. Sibling of registry_dockerio_domain; shares the registry_proxy_server_user headscale identity / ACL group."
  default     = "registry-ghcrio"
}

variable "immich_domain" {
  type    = string
  default = "immich"
}

variable "frigate_domain" {
  type    = string
  default = "frigate"
}

variable "frigate_config_size" {
  type    = string
  default = "10Gi"
}

variable "frigate_recordings_size" {
  type    = string
  default = "500Gi"
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

variable "image_navidrome" {
  type    = string
  default = "deluan/navidrome:latest"
}

variable "navidrome_data_size" {
  type    = string
  default = "5Gi"
}

variable "navidrome_music_size" {
  type    = string
  default = "100Gi"
}

variable "jellyfin_domain" {
  type    = string
  default = "jellyfin"
}

variable "image_jellyfin" {
  type    = string
  default = "jellyfin/jellyfin:latest"
}

variable "jellyfin_config_size" {
  type    = string
  default = "5Gi"
}

variable "jellyfin_cache_size" {
  type    = string
  default = "20Gi"
}

variable "jellyfin_render_gid" {
  description = "Host GID of the `render` group on the K3s node. Used as a supplemental group on the Jellyfin container so it can open /dev/dri/renderD128 for VAAPI. Discover with `getent group render` on the node. Fedora 41 default is 105."
  type        = number
  default     = 105
}

variable "jellyfin_video_gid" {
  description = "Host GID of the `video` group on the K3s node. Used as a supplemental group on the Jellyfin container so it can open /dev/dri/card0 (mode 0660 root:video) for VAAPI. Discover with `getent group video` on the node. Fedora 41 default is 39."
  type        = number
  default     = 39
}

variable "image_homeassist" {
  type    = string
  default = "ghcr.io/home-assistant/home-assistant:stable"
}

variable "image_homeassist_mosquitto" {
  type    = string
  default = "eclipse-mosquitto:2"
}

variable "image_homeassist_z2m" {
  type    = string
  default = "koenkk/zigbee2mqtt:latest"
}

variable "image_frigate" {
  type    = string
  default = "ghcr.io/blakeblackshear/frigate:stable"
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

variable "mcp_prometheus_log_level" {
  description = "LOG_LEVEL for the prometheus MCP server (debug / info / warning / error)."
  type        = string
  default     = "info"
}

variable "mcp_prometheus_url" {
  description = "Upstream Prometheus base URL for the MCP server. Default points at the in-cluster monitoring stack; set to an external/Mimir URL to retarget."
  type        = string
  default     = "http://prometheus.monitoring.svc.cluster.local:9090"
}

variable "mcp_litellm_log_level" {
  description = "LOG_LEVEL for the litellm MCP server (debug / info / warning / error)."
  type        = string
  default     = "info"
}

variable "mcp_litellm_upstream_timeout" {
  description = "httpx timeout (seconds) for upstream LiteLLM calls. /user/daily/activity and /spend/logs can be slow on busy proxies; bump if you see 'LiteLLM timed out' ToolErrors but /key/info returns promptly."
  type        = number
  default     = 60
}

variable "mcp_litellm_max_logs" {
  description = "Hard cap on rows pulled from /spend/logs per tool call. Aggregation tools also respect it. Bump if monthly summaries return truncated=true."
  type        = number
  default     = 2000
}

variable "mcp_litellm_key_hashes" {
  description = "Map from MCP tenant name (must match an entry in var.mcp_api_key_users) to a list of LiteLLM virtual-key hashes that tenant's MCP bearer is allowed to query spend for. Missing tenants or empty lists mean the tenant can query no spend. Hashes aren't secret — they're only filters against LiteLLM's DB, which authenticates via the master key the MCP pod holds. The hash is the 64-char lowercase hex shown as 'Hashed Token' in the LiteLLM UI."
  type        = map(list(string))
  default     = {}
}

variable "mcp_time_log_level" {
  description = "LOG_LEVEL for the time MCP server (debug / info / warning / error)."
  type        = string
  default     = "info"
}

variable "mcp_time_default_timezone" {
  description = "IANA zone the time MCP server uses when a tool call omits the timezone arg. Validated at pod boot (invalid zone crashes the pod)."
  type        = string
  default     = "America/Chicago"
}

variable "mcp_k8s_log_level" {
  description = "LOG_LEVEL for the mcp-k8s server (debug / info / warning / error)."
  type        = string
  default     = "info"
}

variable "mcp_k8s_allowed_namespaces" {
  description = "Namespaces the mcp-k8s server can read pods/logs/events from. Each entry gets a Role+RoleBinding scoped to that namespace; nothing else is reachable. Empty list = no access (server starts but every tool call returns RBAC forbidden). All listed namespaces must already exist at apply time. The `monitoring` namespace is created by the monitoring deployment (applied after this one), so add it after the monitoring deployment exists."
  type        = list(string)
  default = [
    # `default` is included so upstream tools that default to the caller's
    # current namespace (events_list with no namespace arg) don't 403 —
    # there are no workloads here, so read grants are benign.
    "default",
    "builder",
    "exitnode",
    "frigate",
    "homeassist",
    "kube-system",
    "litellm",
    "mcp",
    "monitoring",
    "navidrome",
    "nextcloud",
    "pihole",
    "radicale",
    "registry",
    "registry-proxy",
    "searxng",
    "thunderbolt",
    "tls-rotator",
    # `vault` intentionally omitted — vault logs can include unseal /
    # key-material context; no MCP bearer should be able to read them.
    # Use `kubectl logs -n vault` out-of-band for vault debugging.
  ]
}

variable "image_haproxy" {
  type = string
  # Pulled from AWS Public ECR's mirror of Docker Official Images instead of
  # docker.io directly — the rotator fronts the docker.io mirror, so it can't
  # boot when its own image is the one rate-limited there. ECR public is
  # rate-limit-free for unauthenticated pulls. Equivalent to
  # docker.io/library/haproxy:2.9-alpine.
  # docker.io's official Docker library image (canonical source — public.ecr.aws
  # mirrors this same upstream). Routes through registry-dockerio cache.
  default = "haproxy:2.9-alpine"
}

variable "searxng_domain" {
  type    = string
  default = "searxng"
}

variable "image_searxng" {
  type    = string
  default = "docker.io/searxng/searxng:latest"
}

variable "mcp_shared_domain" {
  type    = string
  default = "mcp-shared"
}

variable "mcp_api_key_users" {
  description = "Named consumers of the shared MCP auth pool. One random Bearer key is minted per name and stored at vault `mcp/auth` under `api_key_<name>`, plus the aggregate `api_keys_csv` that every MCP pod reads."
  type        = list(string)
  default     = ["thunderbolt", "litellm", "claude", "opencode"]
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
  # Keycloak publishes the same image to both quay.io and docker.io —
  # docker.io routes through registry-dockerio cache.
  default = "keycloak/keycloak:26.0"
}

# Domain subdomains for services owned by the `monitoring` deployment. The
# tls-rotator worker (nextcloud deployment) needs to know each cert's FQDN to
# pass to lego, so these are duplicated here. Defaults must match
# monitoring/variables.tf or rotation will issue certs for the wrong CN.
variable "grafana_domain" {
  type    = string
  default = "grafana"
}

variable "ntfy_domain" {
  type    = string
  default = "ntfy"
}

variable "openobserve_domain" {
  type    = string
  default = "openobserve"
}

variable "tls_rotator_renew_threshold_days" {
  description = "Renew any cert with fewer than this many days until expiry. Let's Encrypt issues 90-day certs; 30 leaves a healthy retry window."
  type        = number
  default     = 30
}

variable "tls_rotator_schedule" {
  description = "Cron schedule for the tls-rotator CronJob. Daily, off-peak."
  type        = string
  default     = "0 4 * * *"
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

  mcp_searxng_image       = "${local.thunderbolt_registry}/mcp-searxng:latest"
  mcp_filesystem_image    = "${local.thunderbolt_registry}/mcp-filesystem:latest"
  mcp_memory_image        = "${local.thunderbolt_registry}/mcp-memory:latest"
  mcp_prometheus_image    = "${local.thunderbolt_registry}/mcp-prometheus:latest"
  mcp_time_image          = "${local.thunderbolt_registry}/mcp-time:latest"
  mcp_k8s_image           = "${local.thunderbolt_registry}/mcp-k8s:latest"
  mcp_litellm_image       = "${local.thunderbolt_registry}/mcp-litellm:latest"

  mcp_shared_fqdn = "${var.mcp_shared_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"

  # Backends the shared nginx proxies to. `upstream_path` is where each
  # backend mounts its MCP endpoint. All fastmcp servers mount at `/`,
  # and every MCP is addressed uniformly as `/mcp-<name>/`.
  mcp_backend_services = {
    "mcp-filesystem" = { upstream_path = "/" }
    "mcp-memory"     = { upstream_path = "/" }
    "mcp-searxng"    = { upstream_path = "/" }
    "mcp-prometheus" = { upstream_path = "/" }
    "mcp-time"       = { upstream_path = "/" }
    "mcp-litellm"    = { upstream_path = "/" }
    "mcp-k8s"        = { upstream_path = "/" }
  }

  exitnode_tinyproxy_image = "${local.thunderbolt_registry}/exitnode-tinyproxy:latest"

  searxng_ranker_image = "${local.thunderbolt_registry}/searxng-ranker:latest"
}
