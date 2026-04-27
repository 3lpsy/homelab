terraform {
  required_providers {
    headscale = {
      source                = "awlsring/headscale"
      version               = "~>0.5.0"
      configuration_aliases = [headscale]
    }
  }
}

data "local_file" "api_key" {
  filename = var.headscale_key_path
}

resource "headscale_user" "users" {
  for_each = var.tailnet_users
  name     = each.value
  lifecycle {
    prevent_destroy = true
  }
}

resource "headscale_pre_auth_key" "nomad_server" {
  user = headscale_user.users["nomad_server_user"].id
}

resource "headscale_pre_auth_key" "tv" {
  user           = headscale_user.users["tv_user"].id
  reusable       = true
  time_to_expire = "3y"
}


resource "headscale_pre_auth_key" "ollama" {
  user           = headscale_user.users["ollama_server_user"].id
  reusable       = true
  time_to_expire = "3y"
}

resource "headscale_pre_auth_key" "headscale_host" {
  user           = headscale_user.users["headscale_host_user"].id
  reusable       = true
  time_to_expire = "3y"
}

locals {
  acl_groups = {
    "group:personal"               = ["${var.tailnet_users["personal_user"]}@"]
    "group:personal-laptop"        = ["${var.tailnet_users["personal_laptop_user"]}@"]
    "group:node-server"            = ["${var.tailnet_users["nomad_server_user"]}@"]
    "group:mobile"                 = ["${var.tailnet_users["mobile_user"]}@"]
    "group:tablet"                 = ["${var.tailnet_users["tablet_user"]}@"]
    "group:deck"                   = ["${var.tailnet_users["deck_user"]}@"]
    "group:devbox"                 = ["${var.tailnet_users["devbox_user"]}@"]
    "group:exitnodes"              = ["${var.tailnet_users["exit_node_user"]}@"]
    "group:tv"                     = ["${var.tailnet_users["tv_user"]}@"]
    "group:syncthing-clients"      = ["${var.tailnet_users["personal_user"]}@", "${var.tailnet_users["mobile_user"]}@", "${var.tailnet_users["tablet_user"]}@", "${var.tailnet_users["deck_user"]}@"]
    "group:vault-server"           = ["${var.tailnet_users["vault_server_user"]}@"]
    "group:vault-clients"          = ["${var.tailnet_users["vault_server_user"]}@", "${var.tailnet_users["personal_user"]}@", "${var.tailnet_users["nomad_server_user"]}@", "${var.tailnet_users["pod_provisioner_user"]}@"]
    "group:nextcloud-clients"      = ["${var.tailnet_users["nextcloud_server_user"]}@", "${var.tailnet_users["collabora_server_user"]}@", "${var.tailnet_users["personal_user"]}@", "${var.tailnet_users["mobile_user"]}@"]
    "group:nextcloud-server"       = ["${var.tailnet_users["nextcloud_server_user"]}@"]
    "group:collabora-server"       = ["${var.tailnet_users["collabora_server_user"]}@"]
    "group:pihole-clients"         = ["${var.tailnet_users["personal_user"]}@", "${var.tailnet_users["mobile_user"]}@", "${var.tailnet_users["tv_user"]}@"]
    "group:calendar-clients"       = ["${var.tailnet_users["calendar_server_user"]}@", "${var.tailnet_users["personal_user"]}@", "${var.tailnet_users["mobile_user"]}@"]
    "group:calendar-server"        = ["${var.tailnet_users["calendar_server_user"]}@"]
    "group:homeassist-clients"     = ["${var.tailnet_users["homeassist_server_user"]}@", "${var.tailnet_users["personal_user"]}@", "${var.tailnet_users["mobile_user"]}@"]
    "group:homeassist-server"      = ["${var.tailnet_users["homeassist_server_user"]}@"]
    "group:frigate-clients"        = ["${var.tailnet_users["frigate_server_user"]}@", "${var.tailnet_users["personal_user"]}@", "${var.tailnet_users["mobile_user"]}@"]
    "group:frigate-server"         = ["${var.tailnet_users["frigate_server_user"]}@"]
    "group:registry-clients"       = ["${var.tailnet_users["registry_server_user"]}@", "${var.tailnet_users["nomad_server_user"]}@", "${var.tailnet_users["personal_user"]}@", "${var.tailnet_users["builder_user"]}@"]
    "group:registry-proxy-server"  = ["${var.tailnet_users["registry_proxy_server_user"]}@"]
    "group:registry-proxy-clients" = ["${var.tailnet_users["nomad_server_user"]}@", "${var.tailnet_users["personal_user"]}@", "${var.tailnet_users["builder_user"]}@"]
    "group:grafana-clients"        = ["${var.tailnet_users["grafana_server_user"]}@", "${var.tailnet_users["mobile_user"]}@", "${var.tailnet_users["personal_user"]}@"]
    "group:grafana-server"         = ["${var.tailnet_users["grafana_server_user"]}@"]
    "group:openwrt"                = ["${var.tailnet_users["openwrt_user"]}@"]
    "group:prometheus"             = ["${var.tailnet_users["prometheus_user"]}@"]
    "group:registry-server"        = ["${var.tailnet_users["registry_server_user"]}@"]
    "group:pihole-server"          = ["${var.tailnet_users["pihole_server_user"]}@"]
    "group:ntfy-server"            = ["${var.tailnet_users["ntfy_server_user"]}@"]
    "group:ntfy-clients"           = ["${var.tailnet_users["prometheus_user"]}@", "${var.tailnet_users["grafana_server_user"]}@", "${var.tailnet_users["mobile_user"]}@", "${var.tailnet_users["personal_user"]}@"]
    "group:ollama-server"          = ["${var.tailnet_users["ollama_server_user"]}@"]
    "group:litellm-server"         = ["${var.tailnet_users["litellm_server_user"]}@", "${var.tailnet_users["thunderbolt_server_user"]}@"]
    "group:litellm-clients"        = ["${var.tailnet_users["personal_user"]}@", "${var.tailnet_users["mobile_user"]}@", "${var.tailnet_users["thunderbolt_server_user"]}@", "${var.tailnet_users["mcp_user"]}@"]
    "group:mcp"                    = ["${var.tailnet_users["mcp_user"]}@"]
    "group:searxng-clients"        = ["${var.tailnet_users["personal_user"]}@", "${var.tailnet_users["mobile_user"]}@", "${var.tailnet_users["litellm_server_user"]}@", "${var.tailnet_users["thunderbolt_server_user"]}@", "${var.tailnet_users["mcp_user"]}@"]
    "group:searxng-server"         = ["${var.tailnet_users["searxng_server_user"]}@"]
    "group:log-server"             = ["${var.tailnet_users["log_server_user"]}@"]
    "group:log-clients"            = ["${var.tailnet_users["log_server_user"]}@", "${var.tailnet_users["personal_user"]}@", "${var.tailnet_users["mobile_user"]}@", "${var.tailnet_users["headscale_host_user"]}@"]
    "group:headscale-host"         = ["${var.tailnet_users["headscale_host_user"]}@"]
  }

  acl_acls = [
    # access to self
    { action = "accept", src = ["group:personal"], dst = ["group:personal:*"] },
    { action = "accept", src = ["group:personal-laptop"], dst = ["group:personal:22"] },
    { action = "accept", src = ["group:mobile"], dst = ["group:mobile:*"] },
    { action = "accept", src = ["group:tablet"], dst = ["group:tablet:*"] },
    { action = "accept", src = ["group:deck"], dst = ["group:deck:*"] },
    { action = "accept", src = ["group:node-server"], dst = ["group:node-server:*"] },
    { action = "accept", src = ["group:vault-server"], dst = ["group:vault-server:*"] },
    { action = "accept", src = ["group:collabora-server"], dst = ["group:collabora-server:*"] },
    { action = "accept", src = ["group:nextcloud-server"], dst = ["group:nextcloud-server:*"] },

    # personal management access to k3s
    { action = "accept", src = ["group:personal"], dst = ["group:node-server:22,80,443,6443"] },

    # k3s + pihole resolve DNS broadly
    { action = "accept", src = ["group:node-server"], dst = ["*:65535"] },
    { action = "accept", src = ["group:pihole-server"], dst = ["*:65535"] },

    # syncthing peer-to-peer (tcp + cast)
    { action = "accept", src = ["group:syncthing-clients"], dst = ["group:syncthing-clients:22000,21027"] },

    # calendar / homeassist / frigate clients
    { action = "accept", src = ["group:calendar-clients"], dst = ["group:calendar-server:443"] },
    { action = "accept", src = ["group:homeassist-clients"], dst = ["group:homeassist-server:443"] },
    { action = "accept", src = ["group:frigate-clients"], dst = ["group:frigate-server:443"] },

    # ollama + mcp
    { action = "accept", src = ["group:personal", "group:mobile"], dst = ["group:ollama-server:*"] },
    { action = "accept", src = ["group:personal", "group:mobile", "group:litellm-server"], dst = ["group:mcp:443"] },

    # litellm proxy + backend
    { action = "accept", src = ["group:litellm-clients"], dst = ["group:litellm-server:443"] },
    { action = "accept", src = ["group:litellm-server"], dst = ["group:ollama-server:11434"] },

    # searxng clients
    { action = "accept", src = ["group:searxng-clients"], dst = ["group:searxng-server:443"] },

    # vault, nextcloud, registry, registry-proxy, grafana
    { action = "accept", src = ["group:vault-clients"], dst = ["group:vault-server:443,8201"] },
    { action = "accept", src = ["group:nextcloud-clients"], dst = ["group:nextcloud-server:443", "group:collabora-server:443"] },
    { action = "accept", src = ["group:registry-clients"], dst = ["group:registry-server:443"] },
    { action = "accept", src = ["group:registry-proxy-clients"], dst = ["group:registry-proxy-server:443"] },
    { action = "accept", src = ["group:grafana-clients"], dst = ["group:grafana-server:443"] },

    # prometheus scrapes
    { action = "accept", src = ["group:prometheus"], dst = ["group:openwrt:9100"] },
    { action = "accept", src = ["group:prometheus"], dst = ["group:node-server:9100,10250"] },

    # personal management
    { action = "accept", src = ["group:personal"], dst = ["group:openwrt:22,80,443,9100"] },
    { action = "accept", src = ["group:personal"], dst = ["group:prometheus:9090,9093"] },

    # devbox
    { action = "accept", src = ["group:mobile"], dst = ["group:devbox:1420,1421,3000,8888"] },
    { action = "accept", src = ["group:personal"], dst = ["group:devbox:22"] },

    # pihole
    { action = "accept", src = ["*"], dst = ["group:pihole-server:53"] },
    { action = "accept", src = ["group:personal", "group:mobile"], dst = ["group:pihole-server:443"] },

    # ntfy
    { action = "accept", src = ["group:ntfy-clients"], dst = ["group:ntfy-server:443"] },

    # openobserve ingest + UI on 443
    { action = "accept", src = ["group:log-clients"], dst = ["group:log-server:443"] },

    # personal SSH to exit nodes
    { action = "accept", src = ["group:personal"], dst = ["group:exitnodes:22", "tag:exitnode:22"] },

    # users who can route through any exit node (searxng uses cluster proxy, not strictly needed here)
    { action = "accept", src = ["group:personal", "group:mobile", "group:tv", "group:devbox", "group:mcp", "group:searxng-server"], dst = ["autogroup:internet:*"] },
    { action = "accept", src = ["group:personal", "group:mobile", "group:tv", "group:devbox", "group:mcp", "group:searxng-server"], dst = ["group:exitnodes:*", "tag:exitnode:*"] },
  ]

  acl_policy = {
    groups        = local.acl_groups
    autoApprovers = { exitNode = ["tag:exitnode"] }
    tagOwners     = { "tag:exitnode" = ["group:exitnodes"] }
    hosts         = {}
    acls          = local.acl_acls
  }
}

resource "headscale_policy" "main" {
  policy = jsonencode(local.acl_policy)
}
