locals {
  # ─────────────────────────────────────────────────────────────────────
  # Group definitions
  # Every group below maps to exactly one or more headscale users.
  # No more "*-clients" meta-groups — rules name their src groups directly.
  # ─────────────────────────────────────────────────────────────────────

  # Human / device identities
  identity_groups = {
    "group:personal"        = ["${var.tailnet_users["personal_user"]}@"]
    "group:personal-laptop" = ["${var.tailnet_users["personal_laptop_user"]}@"]
    "group:mobile"          = ["${var.tailnet_users["mobile_user"]}@"]
    "group:tablet"          = ["${var.tailnet_users["tablet_user"]}@"]
    "group:deck"            = ["${var.tailnet_users["deck_user"]}@"]
    "group:devbox"          = ["${var.tailnet_users["devbox_user"]}@"]
    "group:tv"              = ["${var.tailnet_users["tv_user"]}@"]
  }

  # Infrastructure hosts and automation identities
  infra_groups = {
    "group:node-server"     = ["${var.tailnet_users["nomad_server_user"]}@"]
    "group:openwrt"         = ["${var.tailnet_users["openwrt_user"]}@"]
    "group:headscale-host"  = ["${var.tailnet_users["headscale_host_user"]}@"]
    "group:ollama-server"   = ["${var.tailnet_users["ollama_server_user"]}@"]
    "group:exitnodes"       = ["${var.tailnet_users["exit_node_user"]}@"]
    "group:pod-provisioner" = ["${var.tailnet_users["pod_provisioner_user"]}@"]
    "group:builder"         = ["${var.tailnet_users["builder_user"]}@"]
  }

  # Cluster service server identities
  service_groups = {
    "group:vault-server"          = ["${var.tailnet_users["vault_server_user"]}@"]
    "group:nextcloud-server"      = ["${var.tailnet_users["nextcloud_server_user"]}@"]
    "group:collabora-server"      = ["${var.tailnet_users["collabora_server_user"]}@"]
    "group:pihole-server"         = ["${var.tailnet_users["pihole_server_user"]}@"]
    "group:calendar-server"       = ["${var.tailnet_users["calendar_server_user"]}@"]
    "group:homeassist-server"     = ["${var.tailnet_users["homeassist_server_user"]}@"]
    "group:frigate-server"        = ["${var.tailnet_users["frigate_server_user"]}@"]
    "group:registry-server"       = ["${var.tailnet_users["registry_server_user"]}@"]
    "group:registry-proxy-server" = ["${var.tailnet_users["registry_proxy_server_user"]}@"]
    "group:grafana-server"        = ["${var.tailnet_users["grafana_server_user"]}@"]
    "group:prometheus"            = ["${var.tailnet_users["prometheus_user"]}@"]
    "group:ntfy-server"           = ["${var.tailnet_users["ntfy_server_user"]}@"]
    "group:log-server"            = ["${var.tailnet_users["log_server_user"]}@"]
    "group:litellm-server"        = ["${var.tailnet_users["litellm_server_user"]}@"]
    "group:thunderbolt-server"    = ["${var.tailnet_users["thunderbolt_server_user"]}@"]
    "group:mcp"                   = ["${var.tailnet_users["mcp_user"]}@"]
    "group:searxng-server"        = ["${var.tailnet_users["searxng_server_user"]}@"]
  }

  acl_groups = merge(local.identity_groups, local.infra_groups, local.service_groups)

  # ─────────────────────────────────────────────────────────────────────
  # ACL partials — one block per service or concern.
  # Each block is the FULL set of rules concerning that service.
  # Rules where the same group appears in src and dst (self-traffic) are
  # NOT repeated here — acls_self at the bottom of this file covers them
  # for every group.
  # ─────────────────────────────────────────────────────────────────────

  # DNS — k3s + pihole need broad outbound to resolve; everyone can hit pihole:53.
  acls_dns = [
    { action = "accept", src = ["group:node-server"], dst = ["*:65535"] },
    { action = "accept", src = ["group:pihole-server"], dst = ["*:65535"] },
    { action = "accept", src = ["*"], dst = ["group:pihole-server:53"] },
  ]

  # Personal admin — non-SSH management ports to infra hosts. (SSH lives in acls_ssh.)
  acls_personal_admin = [
    { action = "accept", src = ["group:personal"], dst = ["group:node-server:80,443,6443"] },
    { action = "accept", src = ["group:personal"], dst = ["group:openwrt:80,443,9100"] },
  ]

  # Syncthing peer-to-peer (personal, mobile, tablet, deck talk to each other).
  acls_syncthing = [
    {
      action = "accept"
      src    = ["group:personal", "group:mobile", "group:tablet", "group:deck"]
      dst    = ["group:personal:22000,21027", "group:mobile:22000,21027", "group:tablet:22000,21027", "group:deck:22000,21027"]
    },
  ]

  # Vault — personal, k3s, and pod-provisioner reach it.
  acls_vault = [
    {
      action = "accept"
      src    = ["group:personal", "group:node-server", "group:pod-provisioner"]
      dst    = ["group:vault-server:443,8201"]
    },
  ]

  # Nextcloud + Collabora — personal/mobile reach both; servers cross-talk.
  acls_nextcloud = [
    { action = "accept", src = ["group:personal", "group:mobile"], dst = ["group:nextcloud-server:443", "group:collabora-server:443"] },
    { action = "accept", src = ["group:nextcloud-server"], dst = ["group:collabora-server:443"] },
    { action = "accept", src = ["group:collabora-server"], dst = ["group:nextcloud-server:443"] },
  ]

  # Pihole admin UI (DNS port 53 lives in acls_dns).
  acls_pihole = [
    { action = "accept", src = ["group:personal", "group:mobile"], dst = ["group:pihole-server:443"] },
  ]

  # Radicale (calendar).
  acls_calendar = [
    { action = "accept", src = ["group:personal", "group:mobile"], dst = ["group:calendar-server:443"] },
  ]

  # Home Assistant.
  acls_homeassist = [
    { action = "accept", src = ["group:personal", "group:mobile"], dst = ["group:homeassist-server:443"] },
  ]

  # Frigate.
  acls_frigate = [
    { action = "accept", src = ["group:personal", "group:mobile"], dst = ["group:frigate-server:443"] },
  ]

  # Container registry + registry-proxy.
  acls_registry = [
    {
      action = "accept"
      src    = ["group:node-server", "group:personal", "group:builder"]
      dst    = ["group:registry-server:443"]
    },
    {
      action = "accept"
      src    = ["group:node-server", "group:personal", "group:builder"]
      dst    = ["group:registry-proxy-server:443"]
    },
  ]

  # Grafana.
  acls_grafana = [
    { action = "accept", src = ["group:personal", "group:mobile"], dst = ["group:grafana-server:443"] },
  ]

  # Prometheus — scrape targets + admin UI for personal.
  acls_prometheus = [
    { action = "accept", src = ["group:prometheus"], dst = ["group:openwrt:9100"] },
    { action = "accept", src = ["group:prometheus"], dst = ["group:node-server:9100,10250"] },
    { action = "accept", src = ["group:personal"], dst = ["group:prometheus:9090,9093"] },
  ]

  # Ntfy.
  acls_ntfy = [
    {
      action = "accept"
      src    = ["group:prometheus", "group:grafana-server", "group:personal", "group:mobile"]
      dst    = ["group:ntfy-server:443"]
    },
  ]

  # OpenObserve (log server) — ingest + UI.
  acls_openobserve = [
    {
      action = "accept"
      src    = ["group:personal", "group:mobile", "group:headscale-host"]
      dst    = ["group:log-server:443"]
    },
  ]

  # Ollama — direct user access + LiteLLM proxy backend (and Thunderbolt, which
  # used to reach Ollama implicitly via its membership in group:litellm-server).
  acls_ollama = [
    { action = "accept", src = ["group:personal", "group:mobile"], dst = ["group:ollama-server:*"] },
    { action = "accept", src = ["group:litellm-server", "group:thunderbolt-server"], dst = ["group:ollama-server:11434"] },
  ]

  # LiteLLM proxy.
  acls_litellm = [
    {
      action = "accept"
      src    = ["group:personal", "group:mobile", "group:thunderbolt-server", "group:mcp"]
      dst    = ["group:litellm-server:443"]
    },
  ]

  # MCP gateway (mcp-shared).
  acls_mcp = [
    {
      action = "accept"
      src    = ["group:personal", "group:mobile", "group:litellm-server"]
      dst    = ["group:mcp:443"]
    },
  ]

  # SearXNG.
  acls_searxng = [
    {
      action = "accept"
      src    = ["group:personal", "group:mobile", "group:litellm-server", "group:thunderbolt-server", "group:mcp"]
      dst    = ["group:searxng-server:443"]
    },
  ]

  # Exit-node routing — internet egress + access to exitnodes-tagged devices.
  # Admin SSH is in acls_ssh.
  acls_exitnodes = [
    {
      action = "accept"
      src    = ["group:personal", "group:mobile", "group:tv", "group:devbox", "group:mcp", "group:searxng-server"]
      dst    = ["autogroup:internet:*"]
    },
    {
      action = "accept"
      src    = ["group:personal", "group:mobile", "group:tv", "group:devbox", "group:mcp", "group:searxng-server"]
      dst    = ["group:exitnodes:*", "tag:exitnode:*"]
    },
  ]

  # SSH — every port-22 grant in one place.
  acls_ssh = [
    { action = "accept", src = ["group:personal-laptop"], dst = ["group:personal:22"] },
    { action = "accept", src = ["group:personal"], dst = ["group:node-server:22"] },
    { action = "accept", src = ["group:personal"], dst = ["group:openwrt:22"] },
    { action = "accept", src = ["group:personal"], dst = ["group:devbox:22"] },
    { action = "accept", src = ["group:personal"], dst = ["group:exitnodes:22", "tag:exitnode:22"] },
  ]

  # Self-access — every group can talk to itself on all ports.
  # Generated automatically from acl_groups so new groups get a self-rule for free.
  acls_self = [
    for g in keys(local.acl_groups) :
    { action = "accept", src = [g], dst = ["${g}:*"] }
  ]

  acl_acls = concat(
    local.acls_dns,
    local.acls_personal_admin,
    local.acls_syncthing,
    local.acls_vault,
    local.acls_nextcloud,
    local.acls_pihole,
    local.acls_calendar,
    local.acls_homeassist,
    local.acls_frigate,
    local.acls_registry,
    local.acls_grafana,
    local.acls_prometheus,
    local.acls_ntfy,
    local.acls_openobserve,
    local.acls_ollama,
    local.acls_litellm,
    local.acls_mcp,
    local.acls_searxng,
    local.acls_exitnodes,
    local.acls_ssh,
    local.acls_self,
  )
}
