version: 0.1

log:
  level: warn

storage:
  filesystem:
    rootdirectory: /var/lib/registry

# Pull-through cache. This registry instance is read-only by design —
# Distribution rejects PUT/POST/DELETE under any /v2/* path when
# `proxy.remoteurl` is set (see registry/proxy/proxyregistry.go upstream;
# there is no codepath that accepts pushes in proxy mode). The first
# request for a blob/manifest fetches from upstream, stores locally, and
# serves; subsequent requests for the same digest serve from disk.
#
# No `auth:` block — access is gated at the tailnet layer via the
# Headscale `registry-proxy-clients` group ACL. Layer-7 auth would add no
# value over that, since (a) the registry can't be written to anyway and
# (b) all served content is public Docker Hub mirrors.
proxy:
  remoteurl: https://registry-1.docker.io

http:
  addr: 0.0.0.0:5000
  headers:
    X-Content-Type-Options: [nosniff]
