{
  // not using tags but we'll define them for now
  "groups": {
    "group:personal": ["${personal_user}"],
    "group:nomad-server": ["${nomad_server_user}"],
    "group:mobile": ["${mobile_user}"]

  },
  "tagOwners": {
    "tag:personal": ["group:personal"],
    "tag:mobile": ["group:mobile"],
    "tag:nomad-server": ["group:nomad-server"]
  },
  "hosts": {},
  "acls": [
    { "action": "accept", "src": ["group:personal"], "dst": ["group:personal:*"] },
    { "action": "accept", "src": ["group:personal"], "dst": ["group:mobile:*"] },
    { "action": "accept", "src": ["group:personal"], "dst": ["group:nomad-server:*"] },
    { "action": "accept", "src": ["group:mobile"], "dst": ["group:mobile:*"] },
    { "action": "accept", "src": ["group:mobile"], "dst": ["group:personal:*"] },
    { "action": "accept", "src": ["group:nomad-server"], "dst": ["nomad-server:*"] }
  ]
}
