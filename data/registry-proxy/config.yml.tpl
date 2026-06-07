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
  # Re-check upstream for a tag → manifest mapping only after the cached entry
  # is older than 7 days; within that window the proxy serves its cached
  # manifest without contacting upstream. So a rolling tag (`:latest`,
  # `:stable`, `:9`, `:pg15`) can be up to 7 days stale before consumers see
  # fresh layers — a `kubectl rollout restart` inside that window still gets
  # the cached manifest. Trades freshness for fewer upstream pulls (Docker Hub
  # rate limit). Blobs are by-digest and unaffected. Distribution's default
  # when unset is 168h / 7 days.
  ttl: 168h

http:
  addr: 0.0.0.0:${listen_port}
  headers:
    X-Content-Type-Options: [nosniff]
