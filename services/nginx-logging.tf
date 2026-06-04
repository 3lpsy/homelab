# Pre-renders the shared `data/nginx/_logging.conf.tpl` snippet once per
# nginx sidecar with that service's resolved log_level. Every nginx
# ConfigMap's `templatefile()` call passes
# `nginx_logging_block = local.nginx_logging_blocks["<svc>"]` and the tpl
# substitutes it inside `http {}` in place of the old per-tpl
# log_format/map/access_log/error_log stanza.
#
# Service keys must match the override keys users put in
# `var.nginx_log_level_overrides`. See `data/nginx/_logging.conf.tpl` for
# the JSON access-log shape (redacted: no $request_uri / $http_referer).

locals {
  _nginx_sidecars = [
    "audiobookshelf",
    "collabora",
    "frigate",
    "git",
    "grafana",
    "headlamp",
    "homeassist",
    "homeassist-z2m",
    "homepage",
    "immich",
    "jellyfin",
    "litellm",
    "llm",
    "mcp-shared",
    "navidrome",
    "nextcloud",
    "ntfy",
    "openobserve",
    "opencode",
    "pdf",
    "pihole",
    "prometheus",
    "qbt",
    "radicale",
    "registry",
    "registry-dockerio",
    "registry-ghcrio",
    "npm",
    "crates",
    "rustical",
    "searxng",
    "syncthing",
    "thunderbolt",
  ]

  nginx_logging_blocks = {
    for svc in local._nginx_sidecars :
    svc => templatefile("${path.module}/../data/nginx/_logging.conf.tpl", {
      log_level          = lookup(var.nginx_log_level_overrides, svc, var.nginx_log_level)
      access_log_enabled = var.nginx_access_log_enabled
      log_static_assets  = var.nginx_log_static_assets
      access_log_target  = "/dev/stdout"
      error_log_target   = "/dev/stderr"
    })
  }
}
