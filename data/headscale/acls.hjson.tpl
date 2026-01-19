{
  // not using tags but we'll define them for now
  "groups": {
    "group:personal": ["${personal_user}@"],
    "group:nomad-server": ["${nomad_server_user}@"],
    "group:mobile": ["${mobile_user}@"],
    "group:tablet": ["${tablet_user}@"],
    "group:deck": ["${deck_user}@"],
    "group:devbox": ["${devbox_user}@"],
    // add calendar when migrated
    "group:ssh-clients": ["${personal_user}@"],
    "group:ssh-servers": ["${deck_user}@"],
    "group:syncthing-clients": ["${personal_user}@","${mobile_user}@","${tablet_user}@","${deck_user}@"],
    "group:calendar-clients": ["${personal_user}@","${mobile_user}@","${tablet_user}@"],
    "group:vault-server": ["${vault_server_user}@"],
    "group:vault-clients": ["${vault_server_user}@", "${personal_user}@", "${nomad_server_user}@"],
    "group:nextcloud-clients": ["${personal_user}@"],
    "group:nextcloud-server": ["${nextcloud_server_user}@"]
  },
  "tagOwners": {
    "tag:personal": ["group:personal"],
    "tag:mobile": ["group:mobile"],
    "tag:tablet": ["group:tablet"],
    "tag:deck": ["group:deck"],
    "tag:nomad-server": ["group:nomad-server"],
    "tag:vault-server": ["group:vault-server"],
    "tag:vault-clients": ["group:vault-clients"],
    "tag:nextcloud-clients": ["group:nextcloud-clients"],
    "tag:nextcloud-server": ["group:nextcloud-server"]
  },
  "hosts": {},
  "acls": [
    //  access to self
    { "action": "accept", "src": ["group:personal"], "dst": ["group:personal:*"] },
    { "action": "accept", "src": ["group:mobile"], "dst": ["group:mobile:*"] },
    { "action": "accept", "src": ["group:tablet"], "dst": ["group:tablet:*"] },
    { "action": "accept", "src": ["group:deck"], "dst": ["group:deck:*"] },
    { "action": "accept", "src": ["group:nomad-server"], "dst": ["group:nomad-server:*"] },
    { "action": "accept", "src": ["group:vault-server"], "dst": ["group:vault-server:*"] },

    // access ssh from personal
    { "action": "accept", "src": ["group:ssh-clients"], "dst": ["group:ssh-servers:22"] },

    // personal access to nomad (k3s), for management
    { "action": "accept", "src": ["group:personal"], "dst": ["group:nomad-server:22,80,443,6443"] },

    // syncthing access to syncthing, tcp port and casting port
    { "action": "accept", "src": ["group:syncthing-clients"], "dst": ["group:syncthing-clients:22000,21027"] },

    // calendar clients access to personal, tmp
    { "action": "accept", "src": ["group:calendar-clients"], "dst": ["group:personal:443"] },

    // vault clients access to vault server
    { "action": "accept", "src": ["group:vault-clients"], "dst": ["group:vault-server:443,8201"] },

    // nextcloud clients access to nextcloud server
    { "action": "accept", "src": ["group:nextcloud-clients"], "dst": ["group:nextcloud-server:443"] },

    // allow ios to access devbox on 1420,1421,3000,8888
    { "action": "accept", "src": ["group:mobile"], "dst": ["group:devbox:1420,1421,3000,8888"] }

  ]
}
