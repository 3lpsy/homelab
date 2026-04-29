version: 0.1

log:
  level: warn

storage:
  filesystem:
    rootdirectory: ${rootdirectory}

# Pull-through cache. Distribution rejects PUT/POST/DELETE under any /v2/*
# path when `proxy.remoteurl` is set. The first request for a blob/manifest
# fetches from upstream, stores locally, and serves; subsequent requests
# for the same digest serve from disk.
#
# No `auth:` block — access is gated at the tailnet layer via the
# Headscale `registry-proxy-server` group ACL. Layer-7 auth would add no
# value over that since (a) the registry can't be written to in proxy mode
# and (b) all served content is public upstream registry images.
proxy:
  remoteurl: ${remoteurl}

http:
  addr: 0.0.0.0:${listen_port}
  headers:
    X-Content-Type-Options: [nosniff]
