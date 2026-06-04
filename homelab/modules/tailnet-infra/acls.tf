locals {
  # ─────────────────────────────────────────────────────────────────────
  # Group definitions
  # Every group below maps to exactly one or more headscale users.
  # No more "*-clients" meta-groups — rules name their src groups directly.
  # ─────────────────────────────────────────────────────────────────────

  # Human / device identities backed by static pre-auth keys (`tailscale up
  # --authkey=…`). Each maps to a single fixed headscale user.
  preauth_human_groups = {
    # Bootstrap-only identity used during day-0 rollout before Zitadel
    # exists. Mirrors group:personal grants 1:1 (every ACL rule that
    # lists group:personal also lists group:provisioner) so the operator
    # can do everything personal can. Let the 30d preauth key expire
    # once OIDC is the steady-state path; drop the mirroring then.
    "group:provisioner"     = ["${var.tailnet_users["provisioner_user"]}@"]
    "group:personal-laptop" = ["${var.tailnet_users["personal_laptop_user"]}@"]
    "group:devbox"          = ["${var.tailnet_users["devbox_user"]}@"]
    "group:tv"              = ["${var.tailnet_users["tv_user"]}@"]
  }

  # OIDC-only identities — headscale users created on first Zitadel sign-in.
  # Conditionally included: empty oidc-name var means the group isn't
  # declared at all (and the post-process below strips any ACL rule that
  # references it). This lets a fresh deployment apply cleanly before
  # Zitadel is up.
  oidc_groups = merge(
    var.personal_user_oidc_name == "" ? {} : {
      "group:personal" = ["${var.personal_user_oidc_name}@"]
    },
    var.partner_user_oidc_name == "" ? {} : {
      "group:partner" = ["${var.partner_user_oidc_name}@"]
    },
  )

  # Infrastructure hosts and automation identities
  infra_groups = {
    "group:node-server"    = ["${var.tailnet_users["nomad_server_user"]}@"]
    "group:openwrt"        = ["${var.tailnet_users["openwrt_user"]}@"]
    "group:headscale-host" = ["${var.tailnet_users["headscale_host_user"]}@"]
    "group:ollama-server"  = ["${var.tailnet_users["ollama_server_user"]}@"]
    "group:exitnodes"      = ["${var.tailnet_users["exit_node_user"]}@"]
  }

  # Cluster service server identities
  service_groups = {
    "group:vault-server"          = ["${var.tailnet_users["vault_server_user"]}@"]
    "group:nextcloud-server"      = ["${var.tailnet_users["nextcloud_server_user"]}@"]
    "group:collabora-server"      = ["${var.tailnet_users["collabora_server_user"]}@"]
    "group:pihole-server"         = ["${var.tailnet_users["pihole_server_user"]}@"]
    "group:calendar-server"       = ["${var.tailnet_users["calendar_server_user"]}@"]
    "group:music-server"          = ["${var.tailnet_users["music_server_user"]}@"]
    "group:homeassist-server"     = ["${var.tailnet_users["homeassist_server_user"]}@"]
    "group:frigate-server"        = ["${var.tailnet_users["frigate_server_user"]}@"]
    "group:registry-server"       = ["${var.tailnet_users["registry_server_user"]}@"]
    "group:registry-proxy-server" = ["${var.tailnet_users["registry_proxy_server_user"]}@"]
    "group:grafana-server"        = ["${var.tailnet_users["grafana_server_user"]}@"]
    "group:prometheus"            = ["${var.tailnet_users["prometheus_user"]}@"]
    "group:ntfy-server"           = ["${var.tailnet_users["ntfy_server_user"]}@"]
    "group:log-server"            = ["${var.tailnet_users["log_server_user"]}@"]
    "group:litellm-server"        = ["${var.tailnet_users["litellm_server_user"]}@"]
    "group:llm-server"            = ["${var.tailnet_users["llm_server_user"]}@"]
    "group:thunderbolt-server"    = ["${var.tailnet_users["thunderbolt_server_user"]}@"]
    "group:mcp"                   = ["${var.tailnet_users["mcp_user"]}@"]
    "group:searxng-server"        = ["${var.tailnet_users["searxng_server_user"]}@"]
    "group:jellyfin-server"       = ["${var.tailnet_users["jellyfin_server_user"]}@"]
    "group:syncthing-server"      = ["${var.tailnet_users["syncthing_server_user"]}@"]
    "group:podcast-server"        = ["${var.tailnet_users["podcast_server_user"]}@"]
    "group:oidc-server"           = ["${var.tailnet_users["oidc_server_user"]}@"]
    "group:headlamp-server"       = ["${var.tailnet_users["headlamp_server_user"]}@"]
    "group:homepage-server"       = ["${var.tailnet_users["homepage_server_user"]}@"]
    "group:opencode-server"       = ["${var.tailnet_users["opencode_server_user"]}@"]
    "group:pdf-server"            = ["${var.tailnet_users["pdf_server_user"]}@"]
    "group:git-server"            = ["${var.tailnet_users["git_server_user"]}@"]
    "group:qbt-server"            = ["${var.tailnet_users["qbt_server_user"]}@"]
  }

  acl_groups = merge(local.preauth_human_groups, local.oidc_groups, local.infra_groups, local.service_groups)

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
    { action = "accept", src = ["group:personal", "group:provisioner"], dst = ["group:node-server:80,443,6443"] },
    { action = "accept", src = ["group:personal", "group:provisioner"], dst = ["group:openwrt:80,443,9100"] },
  ]

  # Syncthing peer-to-peer. Personal devices sync with each other AND with the
  # cluster-hosted syncthing-server pod on tcp:22000. The pod runs with
  # globalAnnounce/localAnnounce/relays disabled — devices add it as a static
  # `tcp://<ts-fqdn>:22000` address. Personal devices can also browse the
  # syncthing-server GUI on :443 for debug.
  acls_syncthing = [
    {
      action = "accept"
      src    = ["group:personal", "group:provisioner", "group:personal-laptop"]
      dst    = ["group:personal:22000,21027"]
    },
    {
      action = "accept"
      src    = ["group:personal", "group:provisioner", "group:personal-laptop", "group:syncthing-server"]
      dst    = ["group:syncthing-server:22000", "group:personal:22000", "group:personal-laptop:22000"]
    },
    {
      action = "accept"
      src    = ["group:personal", "group:provisioner", "group:personal-laptop"]
      dst    = ["group:syncthing-server:443"]
    },
  ]

  # qbt WebUI — no app auth, so tailnet reachability IS the gate.
  # Locked to the personal user only (+ provisioner mirror). The qbt node
  # is its own headscale user (group:qbt-server).
  acls_qbt = [
    {
      action = "accept"
      src    = ["group:personal", "group:provisioner"]
      dst    = ["group:qbt-server:443"]
    },
  ]

  # Vault — personal + k3s reach it. (pod-provisioner removed: workloads
  # that used to dial Vault over the tailnet now go via cluster routing
  # with host_aliases pinning the FQDN to the vault Service ClusterIP.)
  acls_vault = [
    {
      action = "accept"
      src    = ["group:personal", "group:provisioner", "group:node-server"]
      dst    = ["group:vault-server:443,8201"]
    },
  ]

  # Nextcloud + Collabora — personal/mobile reach both; servers cross-talk.
  acls_nextcloud = [
    { action = "accept", src = ["group:personal", "group:provisioner", "group:partner"], dst = ["group:nextcloud-server:443", "group:collabora-server:443"] },
    { action = "accept", src = ["group:nextcloud-server"], dst = ["group:collabora-server:443"] },
    { action = "accept", src = ["group:collabora-server"], dst = ["group:nextcloud-server:443"] },
  ]

  # Pihole admin UI (DNS port 53 lives in acls_dns).
  acls_pihole = [
    { action = "accept", src = ["group:personal", "group:provisioner"], dst = ["group:pihole-server:443"] },
  ]

  # Radicale (calendar).
  acls_calendar = [
    { action = "accept", src = ["group:personal", "group:provisioner", "group:partner"], dst = ["group:calendar-server:443"] },
  ]

  # Jellyfin — personal/mobile/tv reach the media server over the tailnet.
  acls_jellyfin = [
    { action = "accept", src = ["group:personal", "group:provisioner", "group:partner", "group:tv"], dst = ["group:jellyfin-server:443"] },
  ]

  # Stirling-PDF — personal/partner reach the PDF toolkit over the tailnet.
  # Mobile/roaming personal devices reach it via acls_personal_roaming below.
  acls_pdf = [
    { action = "accept", src = ["group:personal", "group:provisioner", "group:partner"], dst = ["group:pdf-server:443"] },
  ]

  # Navidrome (music). Same device set as Syncthing peers — anything that has
  # a copy of the music library locally should be able to stream from the server.
  acls_music = [
    {
      action = "accept"
      src    = ["group:personal", "group:provisioner", "group:personal-laptop"]
      dst    = ["group:music-server:443"]
    },
  ]

  # Audiobookshelf (podcasts) — consumer devices reach the server over the
  # tailnet. Mirrors the music ACL; podcasts are mobile-first listening with
  # desktop web as a secondary surface.
  acls_podcast = [
    {
      action = "accept"
      src    = ["group:personal", "group:provisioner", "group:personal-laptop"]
      dst    = ["group:podcast-server:443"]
    },
  ]

  # Home Assistant.
  acls_homeassist = [
    { action = "accept", src = ["group:personal", "group:provisioner", "group:personal-laptop", "group:partner"], dst = ["group:homeassist-server:443"] },
  ]

  # Frigate.
  acls_frigate = [
    { action = "accept", src = ["group:personal", "group:provisioner", "group:partner"], dst = ["group:frigate-server:443"] },
  ]

  # Thunderbolt (chat / sync UI).
  acls_thunderbolt = [
    { action = "accept", src = ["group:personal", "group:provisioner", "group:personal-laptop", "group:partner"], dst = ["group:thunderbolt-server:443"] },
  ]

  # Container registry + the docker.io / future sibling-mirror cache pods,
  # all of which run as the shared `registry_proxy_server_user` headscale
  # identity (one ACL group, many distinct TS_HOSTNAMEs).
  # Registry pulls from the tailnet (kubelet on the K3s host + personal
  # devices). BuildKit jobs no longer need a tailnet-side ACL allow —
  # they reach registries via cluster routing with host_aliases.
  acls_registry = [
    {
      action = "accept"
      src    = ["group:node-server", "group:personal", "group:provisioner"]
      dst    = ["group:registry-server:443"]
    },
    {
      action = "accept"
      src    = ["group:node-server", "group:personal", "group:provisioner"]
      dst    = ["group:registry-proxy-server:443"]
    },
  ]

  # Grafana.
  acls_grafana = [
    { action = "accept", src = ["group:personal", "group:provisioner"], dst = ["group:grafana-server:443"] },
  ]

  # Opencode — remote opencode `web` server. Personal devices (browser UI
  # + opencode CLI `attach`) reach it on :443. opencode itself reaches
  # LiteLLM and the MCP gateway via in-cluster routing (host_aliases →
  # ClusterIP per feedback_no_egress_only_ts_sidecars), so no outbound
  # ACLs from group:opencode-server are needed.
  acls_opencode = [
    { action = "accept", src = ["group:personal", "group:provisioner"], dst = ["group:opencode-server:443,8000-8999"] },
  ]

  # Forgejo (git.<magic>) — web UI on :443 and SSH on :22 (TS sidecar
  # forwards tailnet :22 → container :2222 via TS_SERVE_CONFIG). Broad
  # access pattern: every personal-identity surface gets git, including
  # the opencode pod's own tailnet identity (`group:opencode-server`) as
  # a belt-and-suspenders fallback — opencode's primary path is still
  # in-cluster ClusterIP via host_aliases (no tailnet hop), per
  # feedback_no_egress_only_ts_sidecars.
  acls_git = [
    {
      action = "accept"
      src = [
        "group:personal",
        "group:provisioner",
        "group:personal-laptop",
        "group:devbox",
        "group:opencode-server",
      ]
      dst = ["group:git-server:443,22"]
    },
  ]

  # Headlamp — k8s viewer UI. Personal admin + roaming (see acls_personal_roaming).
  acls_headlamp = [
    { action = "accept", src = ["group:personal", "group:provisioner"], dst = ["group:headlamp-server:443"] },
  ]

  # Homepage — personal start-page listing every tailnet service. Tailnet
  # ACL is the sole gate (no OIDC inside the app). Intentionally no
  # group:provisioner: accepting the bootstrap-mirror downside documented
  # at the top of preauth_human_groups. Roaming devices granted via
  # acls_personal_roaming.
  acls_homepage = [
    { action = "accept", src = ["group:personal"], dst = ["group:homepage-server:443"] },
  ]

  # Prometheus — scrape targets (egress from prometheus) + admin UI access
  # for personal. UI access is via nginx :443; raw 9090/9093 are no longer
  # exposed to the tailnet (they listen only on the pod-local netns and
  # nginx proxies to them with oauth2-proxy in front).
  acls_prometheus = [
    { action = "accept", src = ["group:prometheus"], dst = ["group:openwrt:9100"] },
    { action = "accept", src = ["group:prometheus"], dst = ["group:node-server:9100,10250"] },
    { action = "accept", src = ["group:personal", "group:provisioner"], dst = ["group:prometheus:443"] },
  ]

  # Ntfy.
  acls_ntfy = [
    {
      action = "accept"
      src    = ["group:prometheus", "group:grafana-server", "group:personal", "group:provisioner"]
      dst    = ["group:ntfy-server:443"]
    },
  ]

  # OpenObserve (log server) — ingest + UI.
  acls_openobserve = [
    {
      action = "accept"
      src    = ["group:personal", "group:provisioner", "group:headscale-host"]
      dst    = ["group:log-server:443"]
    },
  ]

  # Ollama — direct user access + LiteLLM proxy backend (and Thunderbolt, which
  # used to reach Ollama implicitly via its membership in group:litellm-server).
  acls_ollama = [
    { action = "accept", src = ["group:personal", "group:provisioner"], dst = ["group:ollama-server:*"] },
    { action = "accept", src = ["group:litellm-server", "group:thunderbolt-server"], dst = ["group:ollama-server:11434"] },
  ]

  # LiteLLM proxy.
  acls_litellm = [
    {
      action = "accept"
      src    = ["group:personal", "group:provisioner", "group:thunderbolt-server", "group:mcp"]
      dst    = ["group:litellm-server:443"]
    },
  ]

  # Local llama-swap inference (services/llm.tf). Personal devices reach the
  # tailnet UI/API directly; LiteLLM proxies to it in-cluster (ClusterIP +
  # NetworkPolicy, not the tailnet), so it's not listed as a src here.
  acls_llm = [
    {
      action = "accept"
      src    = ["group:personal", "group:provisioner"]
      dst    = ["group:llm-server:443"]
    },
  ]

  # MCP gateway (mcp-shared).
  acls_mcp = [
    {
      action = "accept"
      src    = ["group:personal", "group:provisioner", "group:litellm-server"]
      dst    = ["group:mcp:443"]
    },
  ]

  # Zitadel OIDC console — every personal device can reach it for browser
  # login. Service-to-service OIDC discovery is mostly in-cluster, EXCEPT
  # headscale itself (runs on the EC2, not in the cluster) which performs
  # OIDC discovery against Zitadel at startup and on every login.
  acls_oidc = [
    {
      action = "accept"
      src    = ["group:personal", "group:provisioner", "group:partner", "group:personal-laptop", "group:devbox"]
      dst    = ["group:oidc-server:443"]
    },
    {
      action = "accept"
      src    = ["group:headscale-host"]
      dst    = ["group:oidc-server:443"]
    },
  ]

  # SearXNG.
  acls_searxng = [
    {
      action = "accept"
      src    = ["group:personal", "group:provisioner", "group:litellm-server", "group:thunderbolt-server", "group:mcp"]
      dst    = ["group:searxng-server:443"]
    },
  ]

  # Exit-node routing — internet egress + access to exitnodes-tagged devices.
  # Admin SSH is in acls_ssh.
  acls_exitnodes = [
    {
      action = "accept"
      src    = ["group:personal", "group:provisioner", "group:partner", "group:tv", "group:devbox", "group:mcp", "group:searxng-server"]
      dst    = ["autogroup:internet:*"]
    },
    {
      action = "accept"
      src    = ["group:personal", "group:provisioner", "group:partner", "group:tv", "group:devbox", "group:mcp", "group:searxng-server"]
      dst    = ["group:exitnodes:*", "tag:exitnode:*"]
    },
  ]

  # K8s pod-network subnet route — delphi advertises the cluster pod CIDR
  # via Tailscale (cluster/cluster.tf advertise_routes). For Headscale to
  # actually include the route in a peer's netmap, that peer's ACL must
  # also grant access to the IP range; otherwise Headscale strips the
  # route.
  #
  # NOTE: this ACL grant is only the tailnet-layer permission. End-to-end
  # pod-IP reachability also requires NetworkPolicy permitting tailnet
  # (100.64.0.0/10) ingress to the destination namespace — kube-router on
  # delphi default-denies forwarded packets that don't match a netpol,
  # even though Headscale ACL allows the connection.
  acls_pod_network = [
    {
      action = "accept"
      src    = ["group:personal", "group:provisioner", "group:tv"]
      dst    = ["${var.k8s_pod_cidr}:*"]
    },
  ]

  # tag:personal-roaming — device-class grants for jim's roaming devices
  # (laptop, phone, tablet) that re-onboard via OIDC and get tagged. The
  # tag REPLACES the node's user identity for ACL purposes (headscale
  # spec), so a tagged node loses every group:personal / group:partner
  # grant and only matches rules listed here. This list is intentionally
  # narrower than group:personal — no Vault, no SSH, no kube API, no
  # private push registry, no admin dashboards. (The registry pull-through
  # proxies are allowed — see group:registry-proxy-server below.) Add things
  # explicitly when needed.
  acls_personal_roaming = [
    {
      action = "accept"
      src    = ["tag:personal-roaming"]
      dst = [
        "group:nextcloud-server:443",
        "group:collabora-server:443",
        "group:calendar-server:443",
        "group:jellyfin-server:443",
        "group:music-server:443",
        "group:podcast-server:443",
        "group:homeassist-server:443",
        "group:frigate-server:443",
        "group:thunderbolt-server:443",
        "group:ntfy-server:443",
        "group:pihole-server:443",
        # Needed when the roaming device is ON the tailnet (at home) —
        # any OIDC-app login (Grafana, Nextcloud, Homeassist, etc.)
        # redirects the browser to oidc.<magic>, which resolves via
        # MagicDNS to the in-cluster TS IP and hits this ACL. Off-tailnet
        # the public proxy handles it; this is the in-tailnet path.
        "group:oidc-server:443",
        "group:headlamp-server:443",
        "group:homepage-server:443",
        # :22 = opkssh-backed SSH into the opencode container (Zitadel-gated).
        "group:opencode-server:443,8000-8999,22",
        "group:pdf-server:443",
        "group:litellm-server:443",
        # Registry pull-through caches (docker.io / ghcr.io mirrors + the npm
        # Verdaccio cache + the crates cache) so a roaming laptop can pull
        # images and run npm/cargo through the tailnet. The private push
        # registry (group:registry-server) stays excluded — roaming pulls, not
        # pushes.
        "group:registry-proxy-server:443",
        # Forgejo: web UI + SSH for git push/pull from mobile/laptop.
        "group:git-server:443,22",
        "group:personal:22"
      ]
    },
    # Syncthing — server + own peer ports. Syncthing peers exchange on
    # 22000 (TCP/QUIC) and 21027 (UDP local discovery, but headscale ACL
    # only enforces TCP/UDP without distinguishing — both directions get
    # the port number).
    {
      action = "accept"
      src    = ["tag:personal-roaming"]
      dst = [
        "group:syncthing-server:443,22000",
        "group:personal:22000,21027",
      ]
    },
    # Exit-node egress — internet via tagged exit node + raw exit-node
    # access (e.g. health checks).
    {
      action = "accept"
      src    = ["tag:personal-roaming"]
      dst    = ["autogroup:internet:*"]
    },
    {
      action = "accept"
      src    = ["tag:personal-roaming"]
      dst    = ["group:exitnodes:*", "tag:exitnode:*"]
    },
  ]

  # SSH — every port-22 grant in one place.
  acls_ssh = [
    { action = "accept", src = ["group:personal-laptop"], dst = ["group:personal:22"] },
    { action = "accept", src = ["group:personal", "group:provisioner"], dst = ["group:node-server:22"] },
    { action = "accept", src = ["group:personal", "group:provisioner"], dst = ["group:openwrt:22"] },
    { action = "accept", src = ["group:personal", "group:provisioner"], dst = ["group:devbox:22"] },
    { action = "accept", src = ["group:personal", "group:provisioner"], dst = ["group:exitnodes:22", "tag:exitnode:22"] },
    # opkssh-backed sshd in the opencode pod (opencode container, not the
    # tailscale sidecar). Auth is Zitadel via opkssh; this only opens
    # tailnet reachability to :22. Tailscale SSH (--ssh) is NOT enabled on
    # opencode's sidecar, so plain sshd serves the port.
    { action = "accept", src = ["group:personal", "group:provisioner"], dst = ["group:opencode-server:22"] },
  ]

  # Self-access — every group can talk to itself on all ports.
  # Generated automatically from acl_groups so new groups get a self-rule for free.
  acls_self = [
    for g in keys(local.acl_groups) :
    { action = "accept", src = [g], dst = ["${g}:*"] }
  ]

  _raw_acl_acls = concat(
    local.acls_dns,
    local.acls_personal_admin,
    local.acls_syncthing,
    local.acls_vault,
    local.acls_nextcloud,
    local.acls_pihole,
    local.acls_calendar,
    local.acls_music,
    local.acls_jellyfin,
    local.acls_pdf,
    local.acls_podcast,
    local.acls_homeassist,
    local.acls_frigate,
    local.acls_thunderbolt,
    local.acls_registry,
    local.acls_grafana,
    local.acls_opencode,
    local.acls_git,
    local.acls_headlamp,
    local.acls_homepage,
    local.acls_prometheus,
    local.acls_ntfy,
    local.acls_openobserve,
    local.acls_ollama,
    local.acls_litellm,
    local.acls_llm,
    local.acls_mcp,
    local.acls_searxng,
    local.acls_oidc,
    local.acls_qbt,
    local.acls_exitnodes,
    local.acls_pod_network,
    local.acls_personal_roaming,
    local.acls_ssh,
    local.acls_self,
  )

  # Post-process: strip references to groups/tags that aren't currently
  # defined (because their backing OIDC var is empty). Without this,
  # headscale rejects the whole policy if a rule names an undefined
  # group. Filter is exact-match OR `<ref>:` prefix so port/path-suffixed
  # forms (`group:personal:22000,21027`, `group:personal:22`) are also
  # dropped, while sibling names like `group:personal-laptop` (no `:`
  # after the prefix) survive.
  _undefined_refs = compact([
    var.personal_user_oidc_name == "" ? "group:personal" : "",
    var.personal_user_oidc_name == "" ? "tag:personal-roaming" : "",
    var.partner_user_oidc_name == "" ? "group:partner" : "",
  ])

  acl_acls = [
    for rule in [
      for r in local._raw_acl_acls : merge(r, {
        src = [
          for s in r.src : s
          if alltrue([for ref in local._undefined_refs : s != ref && !startswith(s, "${ref}:")])
        ]
        dst = [
          for d in r.dst : d
          if alltrue([for ref in local._undefined_refs : d != ref && !startswith(d, "${ref}:")])
        ]
      })
    ] : rule if length(rule.src) > 0 && length(rule.dst) > 0
  ]
}
