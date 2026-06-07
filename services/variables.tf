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

variable "rustical_domain" {
  type    = string
  default = "rcal"
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

# iOS / Android HA Companion device IDs. The notify service per device is
# `notify.mobile_app_<id>`; lowercase + underscores. Find via Settings ->
# Devices & Services -> Mobile App, or Developer Tools -> Actions
# (autocompletes `notify.mobile_app_*`). Empty list = no automations
# rendered (package file becomes a no-op).
variable "homeassist_notify_devices" {
  type    = list(string)
  default = []
}

variable "homeassist_z2m_usb_device_path" {
  description = "Stable hostPath of the Zigbee coordinator's USB serial device on the K3s node. Empty until the dongle is plugged in. Find it with `ls -l /dev/serial/by-id/` and use the full `/dev/serial/by-id/usb-Nabu_Casa_Home_Assistant_Connect_ZBT-2_<serial>-if00` path so it survives reboots and re-enumeration."
  type        = string
  default     = ""
}

variable "registry_users" {
  description = "List of registry usernames. `forgejo-runner` is the dedicated CI push/pull user for the Forgejo Actions runner (services/git-runner.tf), isolated + independently rotatable from `internal`."
  type        = list(string)
  default     = ["internal", "jim", "forgejo-runner"]
}

variable "git_runner_version" {
  # forgejo-runner tracks Forgejo's version scheme (12.x), NOT the old 1.x/6.x
  # numbers. Latest stable as of 2026-05-26 is 12.10.2. Bump deliberately and
  # cross-check https://code.forgejo.org/forgejo/runner/releases. The image is
  # built FROM fedora + this binary (data/images/git-runner/Dockerfile) rather
  # than the official data.forgejo.org/forgejo/runner image, because the latter
  # is Alpine with no container runtime (the docs pair it with a privileged
  # docker:dind sidecar) — we bake rootless podman instead.
  description = "Pinned forgejo-runner release built into the git-runner image (data/images/git-runner/Dockerfile)."
  type        = string
  default     = "12.10.2"
}

variable "git_runner_storage_size" {
  description = "PVC size for the Forgejo Actions runner (holds the .runner file + act cache)."
  type        = string
  default     = "20Gi"
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

variable "npm_domain" {
  type        = string
  description = "Tailnet hostname for the read-only, anonymous npm (Verdaccio) cache with a 7-day cooldown. Lives in the registry-proxy namespace; shares the registry_proxy_server_user headscale identity / ACL group."
  default     = "npm"
}

variable "crates_domain" {
  type        = string
  description = "Tailnet hostname for the crates.io caching proxy with a 7-day cooldown. Sibling of npm_domain; shares the registry_proxy_server_user headscale identity / ACL group."
  default     = "crates"
}

# Published crates-proxy image (3lpsy/chilled-crates). Pulled from ghcr.io via
# the node's in-cluster ghcr mirror. Pinned to a version tag (immutable, so the
# mirror's manifest TTL can't serve a stale build); bump to roll a new release.
variable "image_crates_proxy" {
  type    = string
  default = "ghcr.io/3lpsy/chilled-crates:0.3.1"
}

# crates-proxy cooldown wiring. The fork (3lpsy/chilled-crates) reads
# CRATES_IO_PROXY_COOLDOWN, a duration suffix string (s/m/h/d/w; default 0 =
# disabled) — versions whose sparse-index pubtime is newer than the cutoff are
# filtered out. 7d = the supply-chain cooldown requirement. Rendered as a
# single container env in registry-proxy-crates.tf.
variable "crates_proxy_cooldown_env" {
  type        = string
  description = "Env var the chilled-crates fork reads for its publish-age cooldown."
  default     = "CRATES_IO_PROXY_COOLDOWN"
}

variable "crates_proxy_cooldown_value" {
  type        = string
  description = "Duration-suffix value for crates_proxy_cooldown_env (s/m/h/d/w). 7d per the supply-chain cooldown requirement."
  default     = "7d"
}

variable "pip_proxy_cooldown_value" {
  type        = string
  description = "Relative duration for UV_EXCLUDE_NEWER — the PyPI publish-age cooldown (humantime, e.g. \"7 days\" / \"P7D\"). 7d per the supply-chain cooldown requirement; the PyPI analogue of crates_proxy_cooldown_value since there is no pip caching proxy."
  default     = "7 days"
}

# chilled-crates reads LOG_LEVEL (error|warn|info|debug|trace|off; default info).
# RUST_LOG would override it if ever set on the pod.
variable "crates_proxy_log_level" {
  type    = string
  default = "info"
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

# Map key is the Frigate camera name (lowercase, no spaces) — appears in
# UI, RTSP URLs, MQTT topics, recording paths. Passwords land in Vault at
# frigate/config and surface as FRIGATE_RTSP_PASSWORD_<KEY> env vars
# referenced from config.yml via Frigate's `{FRIGATE_*}` interpolation.
# Non-alphanumeric chars in the key are replaced with `_` for env-var
# names; pick simple keys (e.g. "frontdoor", "garage") to avoid surprises.
variable "frigate_cameras" {
  type = map(object({
    ip       = string
    username = string
    password = string
    # Allowed object classes. The model is YOLOv9-c with the image's COCO-80
    # labelmap, so all 80 COCO classes are detectable — but the validation
    # block below intentionally restricts `objects` to this NVR-relevant
    # 17-class subset:
    #   person bicycle car motorcycle airplane bus train truck boat
    #   bird cat dog horse sheep cow elephant bear
    # Widen the validation list if you want a class outside it. See
    # data/frigate/config.yml.tpl `model:` block.
    objects = optional(list(string), ["person"])
    # Per-cam toggle for the Home Assistant person-detection push
    # notification automation. Default false: a camera is silent unless
    # explicitly opted in here AND homeassist_notify_devices is non-empty.
    # Lets you run recording-only cams without notification spam.
    notifications = optional(bool, false)
    # Detect-stream sampling rate. 5 is Frigate's day-1 default; bump
    # per-cam to 10-15 only where PTZ autotracking needs more position
    # updates per second. The R9700 handles well above this at ~12ms/frame,
    # so the bottleneck is normally /dev/shm + substream framerate on
    # the camera itself (Setting → Camera → Video → Sub Stream).
    fps = optional(number, 5)
    # PTZ cams: set `onvif = {}` to opt in. Fixed cams omit the key.
    # ONVIF user on the cam must share `username` + `password` with the
    # RTSP user — the template reuses FRIGATE_RTSP_PASSWORD_<KEY> as the
    # ONVIF password (one credential set, one Vault entry).
    onvif = optional(object({
      port = optional(number, 80)
      autotracking = optional(object({
        enabled              = optional(bool, false)
        calibrate_on_startup = optional(bool, false)
        return_preset        = optional(string, "Home")
        track                = optional(list(string), ["person"])
        timeout              = optional(number, 10)
        zooming              = optional(string, "disabled")
        # Frigate refuses to start with autotracking enabled unless this
        # is non-empty (safety: prevents chasing every passing object).
        # Default `["all"]` references the auto-rendered full-frame zone
        # in data/frigate/config.yml.tpl — effectively "track anywhere
        # in view". Override per-cam (e.g. ["driveway"]) once you define
        # matching entries in `zones` below.
        required_zones = optional(list(string), ["all"])
      }), {})
    }))
    # Per-cam zones. Keys are zone names referenced from
    # `autotracking.required_zones` (and event filters generally).
    # Coordinates: comma-separated polygon vertices as normalised 0.0-1.0
    # floats (Frigate 0.13+ format — pixel coords are deprecated; values
    # are resolution-independent so detect width/height changes don't
    # invalidate them). Empty map + autotracking enabled = template
    # synthesises a single `all` zone covering the whole frame
    # (`0,0,1,0,1,1,0,1`).
    zones = optional(map(object({
      coordinates = string
    })), {})
  }))
  sensitive = true
  default   = {}

  validation {
    condition = alltrue([
      for name, cam in var.frigate_cameras : alltrue([
        for obj in cam.objects : contains(
          ["person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat", "bird", "cat", "dog", "horse", "sheep", "cow", "elephant", "bear"],
          obj,
        )
      ])
    ])
    error_message = "frigate_cameras.*.objects: must be a subset of the YOLOv9-s edgetpu 17-class COCO labelmap (person, bicycle, car, motorcycle, airplane, bus, train, truck, boat, bird, cat, dog, horse, sheep, cow, elephant, bear). Classes like backpack/handbag/etc. are not in the labelmap and would silently never fire."
  }
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

# Shared base image for in-cluster Python jobs/sidecars: the public astral uv +
# CPython image (uv + Python 3.14), pulled via the node's ghcr.io mirror — so it
# needs NO private-registry pull secret (unlike a custom-built image in the
# in-cluster registry, which is why these system pods couldn't pull it). Pinned
# to uv 0.10.4 to match the BuildKit-built images (frigate, bucket-A).
#
# Bucket-D consumers run stdlib-only scripts via `uv run --no-project`, so the
# 7-day publish cooldown is irrelevant there (nothing is resolved). Bucket-E
# consumers that resolve third-party deps at pod start set UV_EXCLUDE_NEWER as a
# container env (var.pip_proxy_cooldown_value) — the cooldown is not baked into
# this upstream image.
variable "python_base_image" {
  type    = string
  default = "ghcr.io/astral-sh/uv:0.10.4-python3.14-alpine"
}

# Digest-pinned sidecar images for bootstrap-critical pods only (registry +
# both registry proxies). These come up from the containerd cache on reboot
# with image_pull_policy=IfNotPresent, so they never need a registry/mirror to
# pull from — breaking the cold-boot chicken-and-egg. The floating image_*
# vars above stay floating for every other (non-bootstrap) service.
variable "image_busybox_pinned" {
  type    = string
  default = "busybox:1.38.0@sha256:fd8d9aa63ba2f0982b5304e1ee8d3b90a210bc1ffb5314d980eb6962f1a9715d"
}

variable "image_nginx_pinned" {
  type    = string
  default = "nginx:1.31.1-alpine@sha256:8b1e78743a03dbb2c95171cc58639fef29abc8816598e27fb910ed2e621e589a"
}

variable "image_tailscale_pinned" {
  type    = string
  default = "tailscale/tailscale:v1.98.4@sha256:25cde9ad76020b0e29229136d0c38b5962e9a0e1774ffac9b0df68e4a37d6cf0"
}

# Nginx sidecar logging verbosity.
#
# Every nginx sidecar emits a single JSON access-log shape (defined in
# `data/nginx/_logging.conf.tpl`) and an error_log at the level resolved
# below. Defaults match the prior hardcoded stanza (crit + access_log on).
#
# To debug one service: set `nginx_log_level_overrides = { frigate = "debug" }`
# in tfvars and apply — Reloader will not catch this (the ConfigMap hash
# annotation will), so the pod rolls automatically.
variable "nginx_log_level" {
  description = "Default error_log level for nginx sidecars (debug|info|notice|warn|error|crit)."
  type        = string
  default     = "crit"
}

variable "nginx_log_level_overrides" {
  description = "Per-service error_log level overrides. Keys are service names (e.g. \"frigate\", \"grafana\")."
  type        = map(string)
  default     = {}
}

variable "nginx_access_log_enabled" {
  description = "Whether nginx sidecars emit access logs. Set false to silence access lines globally."
  type        = bool
  default     = true
}

variable "nginx_log_static_assets" {
  description = "Log SPA static-asset GETs (js/css/svg/png/woff2/etc). Default false drops them — they bloat access logs without ops value."
  type        = bool
  default     = false
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
  default = "docker.io/valkey/valkey:latest"
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
  type = string
  # Pinned: registry:2 floats to latest 2.x. v3 exists (distribution v3) but
  # is a major config/storage change — stay on 2.8.3 until deliberately bumped.
  # Pinned by digest so the in-cluster registry + both proxy pods come up from
  # containerd cache on reboot without needing a registry to pull from.
  default = "registry:2.8.3@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373"
}

variable "image_radicale" {
  type    = string
  default = "ghcr.io/kozea/radicale:latest"
}

variable "image_rustical" {
  type    = string
  default = "ghcr.io/lennart-k/rustical:latest"
}

variable "image_navidrome" {
  type    = string
  default = "deluan/navidrome:latest"
}

variable "pdf_domain" {
  type    = string
  default = "pdf"
}

variable "pdf_storage_size" {
  type    = string
  default = "5Gi"
}

variable "image_stirling_pdf" {
  type    = string
  default = "stirlingtools/stirling-pdf:latest"
}

variable "navidrome_data_size" {
  type    = string
  default = "5Gi"
}

variable "navidrome_music_size" {
  type    = string
  default = "100Gi"
}

variable "media_dropzone_size" {
  type    = string
  default = "50Gi"
}

variable "ingest_syncthing_domain" {
  type    = string
  default = "ingest-syncthing"
}

# qbt download-only client. WebUI on the tailnet at qbt.<magic>; all qbt
# egress is forced through a 3proxy SOCKS5 backend on the exit-node pods
# (ProtonVPN). See services/qbt.tf.
variable "qbt_domain" {
  type    = string
  default = "qbt"
}

variable "image_qbt" {
  type = string
}

variable "qbt_downloads_size" {
  type    = string
  default = "200Gi"
}

variable "qbt_config_size" {
  type    = string
  default = "2Gi"
}

variable "image_ingest_syncthing" {
  type    = string
  default = "syncthing/syncthing:latest"
}

variable "tailnet_device_hostnames" {
  description = <<-EOT
    Map of role-key -> the device's actual tailnet hostname (i.e. the
    name registered with `tailscale up --hostname=<name>`). Used to
    resolve a role-key like "personal" to a dial address like
    "garden.hs.<magic>:22000".

    Override via .env when device hostnames change:
      export TF_VAR_tailnet_device_hostnames='{"personal":"garden","mobile":"iphone","personal-laptop":"ronin"}'

    Missing keys fall back to the role-key itself (so role "personal"
    resolves to "personal.hs.<magic>" if no override is set).
  EOT
  type        = map(string)
  default = {
    personal = "garden"
    mobile   = "iphone"
  }
}

variable "ingest_syncthing_trusted_devices" {
  description = <<-EOT
    Map of device-alias -> Syncthing Device ID for hosts the cluster
    pre-trusts. Each entry adds a <device> to the cluster's Syncthing
    config and shares the `ingest-music` folder with it.

    The map key MUST match the device's tailnet hostname (i.e. its
    TS_HOSTNAME / `tailscale up --hostname=<name>`). The cluster
    resolves the static dial address as
      tcp://<key>.${"$"}{var.headscale_subdomain}.${"$"}{var.headscale_magic_domain}:22000
    so name your laptop's tailnet host "personal" and the map key
    "personal".

    Value = the remote's Syncthing Device ID, copied from its GUI under
    Actions -> Show ID.

    Get the cluster's own Device ID after first apply with:
      kubectl -n ingest exec deploy/syncthing -c syncthing -- syncthing -device-id
    and add it on each remote alongside tcp://ingest-syncthing.<hs>.<magic>:22000.

    Empty values are skipped so applies before populating .env succeed.

    Set via .env:
      export TF_VAR_ingest_syncthing_trusted_devices='{"personal":"ABC1234-..."}'
  EOT
  type        = map(string)
  default = {
    personal = ""
  }
}

variable "litellm_user_keys" {
  description = <<-EOT
    Map of app name -> LiteLLM virtual key (sk-...). Each value is a key
    you create out-of-band via the LiteLLM admin UI/API, scoped to the
    models + budget that app should be allowed to use. Apps reference
    their entry by name (e.g. var.litellm_user_keys["opencode"]) to pull
    a scoped key into Vault rather than handing every workload the
    master key.

    Set via .env:
      export TF_VAR_litellm_user_keys='{"opencode":"sk-...","other-app":"sk-..."}'

    A blank value is allowed (treated as "not yet provisioned") — the
    pod will boot but every LLM call returns 401 until you populate it.

    Known consumers (each needs its own scoped LiteLLM key):
      - opencode — remote opencode `web` server (services/opencode.tf)
  EOT
  type        = map(string)
  sensitive   = true
  default = {
    opencode = ""
  }
}

variable "jellyfin_domain" {
  type    = string
  default = "jellyfin"
}

variable "image_jellyfin_upstream" {
  description = "Upstream Jellyfin image used as the FROM base for the in-cluster build. The runtime image (`local.jellyfin_image`) bakes the 9p4/jellyfin-plugin-sso plugin on top of this."
  type        = string
  default     = "jellyfin/jellyfin:latest"
}

variable "jellyfin_sso_plugin_version" {
  description = "Tag of the 9p4/jellyfin-plugin-sso release whose `sso-authentication_<v>.zip` asset gets baked into the custom Jellyfin image. Bumping this re-fetches and rebuilds. Match the Jellyfin server ABI: 4.0.0.4 targets 10.11.0.0."
  type        = string
  default     = "4.0.0.4"
}

variable "jellyfin_config_size" {
  type    = string
  default = "5Gi"
}

variable "jellyfin_cache_size" {
  type    = string
  default = "20Gi"
}

variable "jellyfin_media_size" {
  type    = string
  default = "1Ti"
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

variable "audiobookshelf_domain" {
  type    = string
  default = "podcast"
}

variable "image_audiobookshelf" {
  type    = string
  default = "advplyr/audiobookshelf:latest"
}

variable "audiobookshelf_config_size" {
  description = "PVC size for the ABS sqlite DB at /config. Small — must be local FS per ABS docs."
  type        = string
  default     = "2Gi"
}

variable "audiobookshelf_metadata_size" {
  description = "PVC size for /metadata: covers, cache, built-in nightly DB backups."
  type        = string
  default     = "10Gi"
}

variable "audiobookshelf_podcasts_size" {
  description = "PVC size for /podcasts: one folder per podcast, all downloaded episodes."
  type        = string
  default     = "200Gi"
}

variable "audiobookshelf_users" {
  description = "List of ABS usernames. The first entry is the root admin (auto-created via POST /init on first boot). Each gets a random_password + Vault KV entry under audiobookshelf/config and is auto-provisioned by the seed Job."
  type        = list(string)
  default     = ["jim"]
}

variable "audiobookshelf_opml_path" {
  description = "Path (relative to repo root) to an OPML file preseeded into the Podcasts library by the seed Job. Default points at data/audiobookshelf/podcasts.opml (gitignored). If the file is absent or empty the seed step is skipped."
  type        = string
  default     = "data/audiobookshelf/podcasts.opml"
}

variable "audiobookshelf_podcast_default_max_episodes" {
  description = "Default `maxEpisodesToKeep` applied to every imported podcast (FIFO retention — newest N kept regardless of listened state). Set to 0 for unlimited. Per-podcast overrides allowed via audiobookshelf_auto_download_podcasts."
  type        = number
  default     = 3
}

variable "audiobookshelf_podcast_default_schedule" {
  description = "Default cron expression for `autoDownloadSchedule`. Auto-download is ON by default for every imported podcast — opt a specific feed out via audiobookshelf_auto_download_podcasts (`{ auto_download = false }`). Per-feed cron overrides via the `schedule` field on the same map. Default = every 4 hours."
  type        = string
  default     = "0 */4 * * *"
}

variable "audiobookshelf_podcast_initial_lookback_days" {
  description = "When the seed Job encounters a freshly-imported podcast (per audiobookshelf_podcast_fresh_import_window_seconds), it initializes lastEpisodeCheck to (now - this many days) so the first scheduled auto-download poll — and the UI's Check-New-Episodes dialog default — grabs the past week of episodes. Older podcasts are left alone since ABS advances their cursor on each poll. Set to 0 to disable seeding."
  type        = number
  default     = 7
}

variable "audiobookshelf_podcast_fresh_import_window_seconds" {
  description = "How long after a library item's addedAt timestamp the seed Job is allowed to rewind its lastEpisodeCheck. Must be longer than the worst-case time between bulk-create and the seed Job's PATCH pass — bulk-create is async, big OPMLs take a while. Default 6h (21600s)."
  type        = number
  default     = 21600
}

variable "audiobookshelf_podcast_mark_finished_percent" {
  description = "Maps to the Podcasts library's `markAsFinishedPercentComplete` setting (0-100). When set, ABS marks an episode as finished once playback crosses this percentage and takes precedence over the time-remaining setting. Set to null to leave ABS's default (10s remaining) in place."
  type        = number
  default     = 94
  validation {
    condition     = var.audiobookshelf_podcast_mark_finished_percent == null || (var.audiobookshelf_podcast_mark_finished_percent >= 0 && var.audiobookshelf_podcast_mark_finished_percent <= 100)
    error_message = "audiobookshelf_podcast_mark_finished_percent must be null or in [0, 100]."
  }
}

variable "audiobookshelf_auto_download_podcasts" {
  description = <<-EOT
    Map of feed URL -> per-podcast override. Auto-download is ON by default
    for every imported podcast (using audiobookshelf_podcast_default_schedule
    + audiobookshelf_podcast_default_max_episodes). Use this map to override
    a specific feed:
      auto_download                (bool; set false to opt OUT of auto-download)
      schedule                     (cron string)
      max_episodes_to_keep         (int; 0 = unlimited)
      max_new_episodes_to_download (int per scheduled check)

    Listed feeds also act as a wait gate: the seed Job retries until each
    listed feed appears in the library before persisting its hash cache.
    Use this when an OPML import is slow and you want the apply to block
    until specific high-priority feeds are present.

    Match key is the feed URL exactly as it appears in your OPML; the
    seed Job normalizes trivial differences (trailing slash, http vs
    https) when matching.
  EOT
  type = map(object({
    _comment                     = optional(string)
    auto_download                = optional(bool)
    schedule                     = optional(string)
    max_episodes_to_keep         = optional(number)
    max_new_episodes_to_download = optional(number)
  }))
  default = {}
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
  type = string
  # ROCm variant for the artemis R9700s (gfx1201/RDNA4). The :stable-rocm image
  # ships ROCm 7.1.1 with gfx12 support, so gfx1201 runs natively — NO
  # HSA_OVERRIDE_GFX_VERSION. Detector is the `onnx` type, which runs through
  # onnxruntime's MIGraphXExecutionProvider (the image exposes MIGraphX + CPU,
  # NOT a standalone ROCMExecutionProvider); model is the self-built YOLOv9-c
  # ONNX (services/frigate-jobs.tf → seed-model init). Compute via /dev/kfd,
  # ffmpeg VAAPI decode via /dev/dri (both host_path mounts in frigate.tf). ~5GB
  # image (vs ~1GB :stable); first pull on artemis takes a while. REQUIRES host
  # kernel >= 7.0.9 — kernel 6.19's amdkfd fails /dev/kfd open for RDNA4 in a
  # container (EINVAL). If pinning a digest, pin a recent build.
  default = "ghcr.io/blakeblackshear/frigate:stable-rocm"
}

variable "image_oauth2_proxy" {
  type = string
  # Pinned (no `:latest`) — image is on the auth path. Bump deliberately
  # after re-reading the upstream changelog. v7.6.0 supports the OIDC
  # provider with object-shaped groups claims, which Zitadel emits at
  # `urn:zitadel:iam:org:project:roles`. Bumped to v7.15.2 for CVE-2025-54576
  # / CVE-2026-34457 / CVE-2026-40575 + Go stdlib refresh; v7.13 swapped
  # session validation from id_token to access_token (Zitadel returns both,
  # transparent for us); skip_auth_routes regex is path-only since v7.11
  # (we don't use that flag); alpha-config break in v7.14 doesn't apply
  # (CLI flags only).
  default = "quay.io/oauth2-proxy/oauth2-proxy:v7.15.2"
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
  type = string
  # Pinned to a stable release (not :main-latest) because OIDC SSO on FOSS
  # has a known LITELLM_LICENSE-gate regression on some main builds
  # (BerriAI/litellm#16866). If SSO breaks after a bump, check the issue
  # for the latest known-good tag before rolling forward.
  default = "ghcr.io/berriai/litellm:v1.83.14-stable"
}

variable "llm_models" {
  description = <<-EOT
    Map of alias name to LiteLLM model config. `provider` selects upstream:
    `bedrock` (AWS IAM creds, optional per-model aws_region) or `llamaswap`
    (local llama-swap on artemis — `model_id` is the llama-swap YAML key;
    LiteLLM calls it as `openai/<model_id>` against the in-cluster `llm`
    endpoint, zero-cost).

    `max_tokens`     = upstream-supported max OUTPUT tokens per request.
                       Propagated to LiteLLM `litellm_params.max_tokens` and
                       to opencode `limit.output`. For llamaswap models this
                       is a per-request output cap (the engine enforces the
                       real ceiling); for bedrock it's the provider cap.
    `context_window` = upstream-supported max INPUT context length (tokens).
                       Propagated to opencode `limit.context`. Required for
                       opencode to render its limit block — schema demands
                       both `context` AND `output` when `limit` is present,
                       and a missing/loose `limit.output` makes opencode
                       hardcode a 32000 output cap (sst/opencode#1735).
    `opencode_options_json` = JSON-encoded string. Decoded and merged into
                       opencode's per-model `options` block (which the AI
                       SDK forwards as request body params). Encoded as a
                       string because HCL's type system can't unify the
                       arbitrarily-shaped options across map entries when
                       declared as `any`. Variable defaults can't call
                       functions, so write the JSON literal directly (e.g.
                       "{\"reasoning_effort\":\"low\"}"). If overriding via
                       tfvars/auto.tfvars from outside the schema block,
                       `jsonencode(...)` works there.
                       Used to work around DeepInfra's vLLM tool-call parser
                       bug for reasoning-mode models (vllm-project/vllm
                       #22578, #24076, #19017): tool calls emitted inside
                       the model's reasoning channel never get extracted
                       as structured `tool_calls`, so opencode halts.
                       Per-family workaround param differs: gpt-oss uses
                       `reasoning_effort`, Qwen3 thinking models use
                       `extra_body.chat_template_kwargs.enable_thinking`.
                       LiteLLM is unaffected (it just forwards body). Only
                       set for models where we've confirmed the bug fires.
    `fake_stream`    = when true, LiteLLM sends `stream: false` upstream and
                       re-emits the buffered response as a fake SSE stream
                       to the client. Used for vLLM streaming-only bugs like
                       Qwen3-Next + hermes parser dropping tool calls into
                       raw `content` text (vllm-project/vllm#31871). Cost:
                       higher time-to-first-token. Different bug class than
                       `opencode_options` reasoning-disable — that addresses
                       reasoning-channel parser bugs that exist in BOTH
                       streaming and non-streaming. Set fake_stream only
                       when a model has a streaming-specific parser failure.
  EOT
  type = map(object({
    provider                    = string
    model_id                    = string
    max_tokens                  = optional(number)
    context_window              = optional(number)
    aws_region                  = optional(string)
    input_cost_per_token        = optional(number)
    output_cost_per_token       = optional(number)
    cache_read_input_token_cost = optional(number)
    opencode_options_json       = optional(string)
    fake_stream                 = optional(bool)
  }))
  default = {
    # ============================================================
    # Local inference on artemis via llama-swap (services/llm.tf,
    # data/llama-swap/config.yaml). provider="llamaswap" → LiteLLM
    # routes to the in-cluster `llm` endpoint as openai/<model_id>;
    # model_id is the llama-swap YAML key. All zero-cost (self-hosted).
    # context_window mirrors each model's `-c` in the llama-swap config;
    # max_tokens is a per-request output cap.
    #
    # No opencode_options_json / fake_stream here: those worked around
    # DeepInfra's vLLM tool-call parser bugs. llama.cpp runs tool-calling
    # via --jinja; if a Qwen3 chat template drops tool_calls, fix it
    # server-side with --chat-template-file in the llama-swap config, not
    # with a per-model request hack.
    # ============================================================

    # Headline: Qwen3.6-35B-A3B MoE, Q6_K, spans both R9700s. Default
    # agentic + code-review model (opencode main model + rust-reviewer).
    "coding-qwen-3.6-35b-a3b" = {
      provider              = "llamaswap"
      model_id              = "qwen3.6-35b-a3b"
      max_tokens            = 8192
      context_window        = 131072
      input_cost_per_token  = 0
      output_cost_per_token = 0
    }

    # Coding specialist, Q6_K, spans both cards (swaps with the headline).
    "coding-qwen3-coder-30b-a3b" = {
      provider              = "llamaswap"
      model_id              = "qwen3-coder-30b-a3b"
      max_tokens            = 8192
      context_window        = 65536
      input_cost_per_token  = 0
      output_cost_per_token = 0
    }

    # EXPERIMENTAL: Qwen3-Coder-Next 80B-A3B, UD-Q4_K_XL (~49.6GB), spans both
    # cards. Hybrid Gated-DeltaNet arch — full 262144 native ctx fits (cheap
    # KV). Present so it's selectable, but NOT opencode's default main; the
    # Vulkan path for this arch is immature (see data/llama-swap/config.yaml
    # block for the gated_delta_net-shader + tool-call-EOS caveats to verify
    # before promoting it).
    "coding-qwen3-coder-next-80b-a3b" = {
      provider              = "llamaswap"
      model_id              = "qwen3-coder-next-80b-a3b"
      max_tokens            = 8192
      context_window        = 262144
      input_cost_per_token  = 0
      output_cost_per_token = 0
    }

    # Small 4B (Q8_0). opencode small_model + explore/commit-msg subagents.
    # Alias name kept (legacy "3.5") so opencode's literal references keep
    # resolving without churn; the GGUF is the original Qwen3-4B.
    "default-qwen-3.5-4b" = {
      provider              = "llamaswap"
      model_id              = "qwen3-4b"
      max_tokens            = 8192
      context_window        = 32768
      input_cost_per_token  = 0
      output_cost_per_token = 0
    }

    # Tiny 1.7B (Q8_0). Fast utility / bulk subtasks.
    "bulk-qwen3-1.7b" = {
      provider              = "llamaswap"
      model_id              = "qwen3-1.7b"
      max_tokens            = 8192
      context_window        = 16384
      input_cost_per_token  = 0
      output_cost_per_token = 0
    }

    # Dense 31B multimodal (Gemma 4, Q5_K_M) — the lineup's vision-capable
    # model (the Qwen entries are text-only). Served with the F16 mmproj so
    # OpenAI image_url content works. Dense → tolerates Q5 well (the MoE
    # higher-bit rule doesn't apply). Spans both cards.
    "default-gemma-4-31b" = {
      provider              = "llamaswap"
      model_id              = "gemma-4-31b"
      max_tokens            = 8192
      context_window        = 65536
      input_cost_per_token  = 0
      output_cost_per_token = 0
    }
  }
}

variable "llm_domain" {
  description = "Subdomain for the local llama-swap inference service (llm.<hs>.<magic>)."
  type        = string
  default     = "llm"
}

variable "llm_model_storage_size" {
  description = "Size of the llm model-cache PVC on artemis local-path (holds the GGUFs)."
  type        = string
  default     = "300Gi"
}

variable "image_curl" {
  description = "TLS-capable curl image used by the llm GGUF-download Job (busybox wget is unreliable for the HF CDN redirect)."
  type        = string
  default     = "curlimages/curl:latest"
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
  description = "Upstream Prometheus base URL for the MCP server. Default points at the in-cluster monitoring stack (with /prometheus path-prefix from --web.external-url); set to an external/Mimir URL to retarget."
  type        = string
  default     = "http://prometheus.prometheus.svc.cluster.local:9090/prometheus"
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
  description = "Namespaces the mcp-k8s server can read pods/logs/events from. Each entry gets a Role+RoleBinding scoped to that namespace; nothing else is reachable. Empty list = no access (server starts but every tool call returns RBAC forbidden). All listed namespaces must already exist at apply time."
  type        = list(string)
  default = [
    # `default` is included so upstream tools that default to the caller's
    # current namespace (events_list with no namespace arg) don't 403 —
    # there are no workloads here, so read grants are benign.
    "default",
    "audiobookshelf",
    "builder",
    "collabora",
    "exitnode",
    "frigate",
    "grafana",
    "headlamp",
    "homeassist",
    "homepage",
    "immich",
    "ingest",
    "jellyfin",
    "kube-state-metrics",
    "kube-system",
    "litellm",
    "mcp",
    "navidrome",
    "nextcloud",
    "node-exporter",
    "ntfy",
    "opencode",
    "openobserve",
    "otel-collector",
    "pihole",
    "prometheus",
    "provisioner",
    "radicale",
    "registry",
    "registry-proxy",
    "reloader",
    "rustical",
    "searxng",
    "thunderbolt",
    "tls-rotator",
    # `oidc` and `vault` intentionally omitted — both can include token /
    # unseal / key-material context in their logs. Use `kubectl logs -n
    # oidc|vault` out-of-band when debugging those.
  ]
}

variable "image_haproxy" {
  type = string
  # docker.io's official Docker library image. Routes through registry-dockerio
  # cache. 2.9 was EOL (last release 2.9.15, 2025-03).
  default = "haproxy:3.3-alpine"
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
  default     = ["thunderbolt", "litellm", "claude", "opencode", "ingestor"]
}

variable "image_thunderbolt_postgres" {
  type = string
  # PG18+ requires the parent dir as the mount (PVC is mounted at
  # /var/lib/postgresql, postgres lays out into /var/lib/postgresql/<MAJOR>/docker/).
  # Mount path in thunderbolt-postgres.tf must match.
  default = "postgres:18-alpine"
}

variable "image_mongo" {
  type    = string
  default = "mongo:7.0"
}

# Domain subdomains for services in the `monitoring` namespace.
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

variable "headlamp_domain" {
  type    = string
  default = "headlamp"
}

variable "homepage_domain" {
  type    = string
  default = "homepage"
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

# ---- monitoring stack (merged from former monitoring/ deployment) ---------

variable "kubeconfig_path" {
  type = string
}

variable "ssh_priv_key_path" {
  type = string
}

variable "grafana_admin_user" {
  type    = string
  default = "admin"
}

variable "grafana_storage_size" {
  type    = string
  default = "5Gi"
}

variable "openwrt_domain" {
  type    = string
  default = "openwrt"
}

variable "prometheus_domain" {
  type    = string
  default = "prometheus"
}

variable "prometheus_retention" {
  type    = string
  default = "30d"
}

variable "prometheus_storage_size" {
  type    = string
  default = "20Gi"
}

variable "ntfy_users" {
  type = map(string)
  default = {
    grafana     = "admin"
    mobile      = "user"
    prometheus  = "user"
    openobserve = "user"
    # Home Assistant publishes Frigate person-detection alerts (and any
    # other HA-side automation notifications) via this user. HA's
    # rest_command lives on the HA PVC; the password lookup is up to the
    # operator (e.g. `vault kv get -field=password_homeassist
    # ntfy/config`).
    homeassist = "user"
  }
}

variable "ntfy_alert_topic" {
  type    = string
  default = "homelab"
}

variable "ntfy_storage_size" {
  type    = string
  default = "2Gi"
}

variable "openobserve_storage_size" {
  type    = string
  default = "100Gi"
}

variable "openobserve_retention_days" {
  type    = number
  default = 7
}

variable "openobserve_org" {
  type        = string
  default     = "default"
  description = "OpenObserve organization slug used in ingest API paths"
}

variable "image_prometheus" {
  type    = string
  default = "prom/prometheus:latest"
}

variable "image_alertmanager" {
  type    = string
  default = "prom/alertmanager:latest"
}

variable "image_node_exporter" {
  type    = string
  default = "prom/node-exporter:latest"
}

variable "image_amd_gpu_device_plugin" {
  type    = string
  default = "rocm/k8s-device-plugin:latest"
}

variable "image_amd_gpu_metrics_exporter" {
  type    = string
  default = "rocm/device-metrics-exporter:v1.5.0"
}

variable "image_kube_state_metrics" {
  type    = string
  default = "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.18.0"
}

variable "image_grafana" {
  type    = string
  default = "grafana/grafana:latest"
}

variable "image_headlamp" {
  type    = string
  default = "ghcr.io/headlamp-k8s/headlamp:latest"
}

variable "image_homepage" {
  type    = string
  default = "ghcr.io/gethomepage/homepage:latest"
}

variable "image_ntfy" {
  type    = string
  default = "binwiederhier/ntfy:latest"
}

variable "image_openobserve" {
  type    = string
  default = "openobserve/openobserve:latest"
}

variable "image_otel_collector" {
  type        = string
  default     = ""
  description = "OTel collector image. Leave empty to use the custom in-cluster build from otel-collector.tf (alpine + systemd + upstream binary). Override only if you explicitly want upstream contrib (no journald receiver support)."
}

variable "zitadel_personal_user" {
  description = <<-EOT
    Personal human user seeded in Zitadel under the homelab org. The first
    non-admin identity used for SSO onboarding (Radicale, Nextcloud, Immich,
    etc). The bootstrap password is auto-generated and stashed in Vault at
    `secret/zitadel-users/<user_name>`; read it once via `vault kv get`,
    log in to Zitadel, set a passkey, then forget it.

    Loginname is constructed by Zitadel as `<user_name>@<org-primary-domain>`
    — after services/zitadel-org-domain.tf flips primary, that's
    `<user_name>@${"$"}{var.headscale_magic_domain}`.

    `nick_name` is optional and surfaces in the Zitadel profile UI only.
  EOT
  type = object({
    user_name  = string
    first_name = string
    last_name  = string
    email      = string
    nick_name  = optional(string)
  })
}

variable "zitadel_partner_user" {
  description = <<-EOT
    Second human seeded in Zitadel under the homelab org — same onboarding
    flow as zitadel_personal_user. Currently granted access to nextcloud,
    homeassist, and rustical (one zitadel_user_grant per service). Bootstrap
    password lands in Vault at `secret/zitadel-users/<user_name>`; read it
    once, log in to Zitadel, set a passkey, then forget it.
  EOT
  type = object({
    user_name  = string
    first_name = string
    last_name  = string
    email      = string
    nick_name  = optional(string)
  })
}

variable "image_reloader" {
  type    = string
  default = "ghcr.io/stakater/reloader:latest"
}

# ─── opencode ──────────────────────────────────────────────────────────────
variable "opencode_domain" {
  description = "Subdomain (under <headscale_subdomain>.<headscale_magic_domain>) where opencode advertises itself on the tailnet. The opencode pod's tailscale sidecar registers under headscale user `opencode` with TS_HOSTNAME = this value, so the resulting FQDN is opencode.<hs>.<magic>."
  type        = string
  default     = "opencode"
}

variable "opencode_storage_size" {
  description = "PVC size for /root/.local/share/opencode — sessions, conversation history, MCP OAuth tokens, and provider sdks (`@ai-sdk/*` install on first boot). Bump if you keep a lot of long chats."
  type        = string
  default     = "5Gi"
}

# ─── Forgejo (services/git.tf) ─────────────────────────────────────────────
variable "git_domain" {
  description = "Subdomain (under <headscale_subdomain>.<headscale_magic_domain>) where the Forgejo forge advertises itself on the tailnet. Headscale user is `git` (var.tailnet_users.git_server_user), so the resulting FQDN is git.<hs>.<magic>."
  type        = string
  default     = "git"
}

variable "image_forgejo" {
  description = "Forgejo container image. Pinned to the latest stable / current LTS (2026-05-12 release, supported through 2027-07-15). Rootless variant runs as UID 1000."
  type        = string
  default     = "codeberg.org/forgejo/forgejo:15.0.2-rootless"
}

variable "git_storage_size" {
  description = "PVC size for the Forgejo /var/lib/gitea data dir (SQLite DB + bare git repos + LFS objects). Single SQLite file; bump as repo count grows."
  type        = string
  default     = "50Gi"
}

variable "git_personal_user_ssh_pub_key" {
  description = "OpenSSH public key for the personal Zitadel-mapped Forgejo user. Supplied via `TF_VAR_git_personal_user_ssh_pub_key`; the bootstrap Job registers it as title `personal-default` so you can `ssh -T git@git.<magic>` immediately after first apply. RSA rejected — use ed25519/ed448/ecdsa."
  type        = string
  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-ed448|ecdsa-sha2-(nistp256|nistp384|nistp521)) ", var.git_personal_user_ssh_pub_key))
    error_message = "Key must be ed25519, ed448, or ecdsa (RSA rejected — modern algos only)."
  }
}

locals {
  nextcloud_image = "${var.registry_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}/nextcloud:latest"

  thunderbolt_registry       = "${var.registry_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  thunderbolt_frontend_image = "${local.thunderbolt_registry}/thunderbolt-frontend:latest"
  thunderbolt_backend_image  = "${local.thunderbolt_registry}/thunderbolt-backend:latest"
  thunderbolt_fqdn           = "${var.thunderbolt_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  thunderbolt_public_url     = "https://${local.thunderbolt_fqdn}"

  mcp_searxng_image    = "${local.thunderbolt_registry}/mcp-searxng:latest"
  mcp_filesystem_image = "${local.thunderbolt_registry}/mcp-filesystem:latest"
  mcp_memory_image     = "${local.thunderbolt_registry}/mcp-memory:latest"
  mcp_prometheus_image = "${local.thunderbolt_registry}/mcp-prometheus:latest"
  mcp_time_image       = "${local.thunderbolt_registry}/mcp-time:latest"
  mcp_k8s_image        = "${local.thunderbolt_registry}/mcp-k8s:latest"
  mcp_litellm_image    = "${local.thunderbolt_registry}/mcp-litellm:latest"

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
  exitnode_3proxy_image    = "${local.thunderbolt_registry}/exitnode-3proxy:latest"

  searxng_ranker_image = "${local.thunderbolt_registry}/searxng-ranker:latest"

  homeassist_image = "${local.thunderbolt_registry}/homeassist:latest"

  jellyfin_image = "${local.thunderbolt_registry}/jellyfin:latest"
}
