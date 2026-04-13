{
  // not using tags but we'll define them for now
  "groups": {
    "group:personal": ["${personal_user}@"],
    "group:node-server": ["${nomad_server_user}@"],
    "group:mobile": ["${mobile_user}@"],
    "group:tablet": ["${tablet_user}@"],
    "group:deck": ["${deck_user}@"],
    "group:devbox": ["${devbox_user}@"],
    "group:exitnodes": ["${exit_node_user}@"],
    "group:tv": ["${tv_user}@"],
    "group:syncthing-clients": ["${personal_user}@","${mobile_user}@","${tablet_user}@","${deck_user}@"],
    "group:vault-server": ["${vault_server_user}@"],
    // immich is also nextcloud TODO move collabora to nextcloud too
    "group:vault-clients": ["${vault_server_user}@", "${personal_user}@", "${nomad_server_user}@"],
    "group:nextcloud-clients": ["${nextcloud_server_user}@", "${collabora_server_user}@", "${personal_user}@", "${mobile_user}@"],
    "group:nextcloud-server": ["${nextcloud_server_user}@"],
    "group:collabora-server": ["${collabora_server_user}@"],
    "group:pihole-clients": ["${personal_user}@", "${mobile_user}@", "${tv_user}@"],
    "group:calendar-clients": ["${calendar_server_user}@", "${personal_user}@", "${mobile_user}@"],
    "group:calendar-server": ["${calendar_server_user}@"],
    "group:registry-clients": ["${registry_server_user}@", "${nomad_server_user}@", "${personal_user}@"],
    "group:grafana-clients": ["${grafana_server_user}@", "${mobile_user}@", "${personal_user}@"],
    "group:grafana-server": ["${grafana_server_user}@"],
    "group:openwrt": ["${openwrt_user}@"],
    "group:prometheus": ["${prometheus_user}@"],
    "group:registry-server": ["${registry_server_user}@"],
    "group:pihole-server": ["${pihole_server_user}@"],
    "group:ntfy-server": ["${ntfy_server_user}@"],
    "group:ntfy-clients": ["${prometheus_user}@", "${grafana_server_user}@", "${mobile_user}@", "${personal_user}@"],
    "group:ollama-server": ["${ollama_server_user}@"],
    "group:litellm-server": ["${litellm_server_user}@"],
    "group:litellm-clients": ["${personal_user}@", "${mobile_user}@"]
  },
  "autoApprovers": {
    "exitNode": ["tag:exitnode"]
  },
  "tagOwners": {
    "tag:exitnode": ["group:exitnodes"]
  },
  "hosts": {},
  "acls": [
    //  access to self
    { "action": "accept", "src": ["group:personal"], "dst": ["group:personal:*"] },
    { "action": "accept", "src": ["group:mobile"], "dst": ["group:mobile:*"] },
    { "action": "accept", "src": ["group:tablet"], "dst": ["group:tablet:*"] },
    { "action": "accept", "src": ["group:deck"], "dst": ["group:deck:*"] },
    { "action": "accept", "src": ["group:node-server"], "dst": ["group:node-server:*"] },
    { "action": "accept", "src": ["group:vault-server"], "dst": ["group:vault-server:*"] },
    { "action": "accept", "src": ["group:collabora-server"], "dst": ["group:collabora-server:*"] },
    { "action": "accept", "src": ["group:nextcloud-server"], "dst": ["group:nextcloud-server:*"] },

    // personal access to nomad (k3s), for management
    { "action": "accept", "src": ["group:personal"], "dst": ["group:node-server:22,80,443,6443"] },

    // let nomad / k3s resolve dns:
    { "action": "accept", "src": ["group:node-server"], "dst": ["*:65535"] },

    // syncthing access to syncthing, tcp port and casting port
    { "action": "accept", "src": ["group:syncthing-clients"], "dst": ["group:syncthing-clients:22000,21027"] },

    // calendar clients access to personal, tmp
    { "action": "accept", "src": ["group:calendar-clients"], "dst": ["group:calendar-server:443"] },

    // let personal talk to ollama
    { "action": "accept", "src": ["group:personal"], "dst": ["group:ollama-server:*"] },

    // litellm
    // litellm clients to litellm proxy
    { "action": "accept", "src": ["group:litellm-clients"], "dst": ["group:litellm-server:4000"] },

    // litellm proxy to ollama backend
    { "action": "accept", "src": ["group:litellm-server"], "dst": ["group:ollama-server:11434"] },

    // personal to litellm ssh
    { "action": "accept", "src": ["group:personal"], "dst": ["group:litellm-server:22"] },
    // vault clients access to vault server
    { "action": "accept", "src": ["group:vault-clients"], "dst": ["group:vault-server:443,8201"] },

    // nextcloud clients access to nextcloud server and collabora server
    { "action": "accept", "src": ["group:nextcloud-clients"], "dst": ["group:nextcloud-server:443", "group:collabora-server:443"] },

    // registry clients access to registry server
    { "action": "accept", "src": ["group:registry-clients"], "dst": ["group:registry-server:443"] },

    // grafana clients access to registry server
    { "action": "accept", "src": ["group:grafana-clients"], "dst": ["group:grafana-server:443"] },

    // prometheus scrapes openwrt
    { "action": "accept", "src": ["group:prometheus"], "dst": ["group:openwrt:9100"] },
    // prometheus to scrape delphi (k3s)
    { "action": "accept", "src": ["group:prometheus"], "dst": ["group:node-server:9100,10250"] },
    // personal management of openwrt
    { "action": "accept", "src": ["group:personal"], "dst": ["group:openwrt:22,80,443,9100"] },

    // allow ios to access devbox on 1420,1421,3000,8888
    { "action": "accept", "src": ["group:mobile"], "dst": ["group:devbox:1420,1421,3000,8888"] },

    // pihole clients to access pihole server
    { "action": "accept", "src": ["*"], "dst": ["group:pihole-server:53"] },

    // pihole managers
    { "action": "accept", "src": ["group:personal", "group:mobile"], "dst": ["group:pihole-server:443"] },

    // ntfy
    { "action": "accept", "src": ["group:ntfy-clients"], "dst": ["group:ntfy-server:443"] },
  { "action": "accept", "src": ["group:personal"], "dst": ["group:exitnodes:22", "tag:exitnode:22"] },

    // users who can use any exit node
    {
      "action": "accept",
      "src": ["group:personal", "group:mobile", "group:tv"],
      "dst": ["autogroup:internet:*"]
    },
  { "action": "accept", "src": ["group:personal", "group:mobile", "group:tv"], "dst": ["group:exitnodes:*", "tag:exitnode:*"] }

  ]
}
