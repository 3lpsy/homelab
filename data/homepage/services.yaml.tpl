---
- Smart Home:
    - Home Assistant:
        href: https://${homeassist_fqdn}
        description: Smart-home hub
        icon: home-assistant.svg
    - Zigbee2MQTT:
        href: https://${homeassist_z2m_fqdn}
        description: Z2M dashboard
        icon: zigbee2mqtt.svg
    - Frigate:
        href: https://${frigate_fqdn}
        description: NVR
        icon: frigate.svg

- Cloud:
    - Nextcloud:
        href: https://${nextcloud_fqdn}
        description: Files, calendar, contacts
        icon: nextcloud.svg
    - Immich:
        href: https://${immich_fqdn}
        description: Photos
        icon: immich.svg
    - Collabora:
        href: https://${collabora_fqdn}
        description: Online office suite
        icon: collabora-online.svg
    - SearXNG:
        href: https://${searxng_fqdn}
        description: Meta search
        icon: searxng.svg
    - Stirling-PDF:
        href: https://${pdf_fqdn}
        description: PDF toolkit
        icon: stirling-pdf.svg

- Media:
    - Jellyfin:
        href: https://${jellyfin_fqdn}
        description: Movies & TV
        icon: jellyfin.svg
    - qbt:
        href: https://${qbt_fqdn}
        description: Download client (VPN-only)
        icon: mdi-download
    - Navidrome:
        href: https://${navidrome_fqdn}
        description: Music
        icon: navidrome.svg
    - Audiobookshelf:
        href: https://${audiobookshelf_fqdn}
        description: Audiobooks & podcasts
        icon: audiobookshelf.svg
    - Ingest UI:
        href: https://${ingest_ui_fqdn}
        description: Media ingest dashboard
        icon: mdi-tray-arrow-down

- Dev/AI:
    - Forgejo:
        href: https://${git_fqdn}
        description: Self-hosted git forge
        icon: mdi-source-branch
    - opencode:
        href: https://${opencode_fqdn}
        description: Remote coding agent
        icon: mdi-code-braces
    - LiteLLM:
        href: https://${litellm_fqdn}
        description: LLM proxy
        icon: mdi-brain
    - llm:
        href: https://${llm_fqdn}
        description: Local inference (llama-swap)
        icon: mdi-expansion-card-variant
    - MCP gateway:
        href: https://${mcp_shared_fqdn}
        description: Model Context Protocol servers
        icon: mdi-server-network
    - Thunderbolt:
        href: https://${thunderbolt_fqdn}
        description: Personal AI app
        icon: mdi-flash

- Admin:
    - Grafana:
        href: https://${grafana_fqdn}
        description: Dashboards
        icon: grafana.svg
    - Prometheus:
        href: https://${prometheus_fqdn}
        description: Metrics
        icon: prometheus.svg
    - OpenObserve:
        href: https://${openobserve_fqdn}
        description: Logs
        icon: mdi-magnify-scan
    - Headlamp:
        href: https://${headlamp_fqdn}
        description: Kubernetes UI
        icon: kubernetes.svg
    - Vault:
        href: https://${vault_fqdn}:8201
        description: Secrets
        icon: vault.svg
    - Pi-hole:
        href: https://${pihole_fqdn}
        description: DNS sinkhole
        icon: pi-hole.svg
    - Registry:
        href: https://${registry_fqdn}
        description: Container registry
        icon: mdi-package-variant-closed
    - Ntfy:
        href: https://${ntfy_fqdn}
        description: Notifications
        icon: mdi-bell-ring
    - Zitadel:
        href: https://${oidc_fqdn}
        description: Identity / SSO
        icon: zitadel.svg
    - Rustical:
        href: https://${rustical_fqdn}
        description: CalDAV / CardDAV
        icon: mdi-calendar-month
    - Radicale:
        href: https://${radicale_fqdn}
        description: CalDAV (legacy, phasing out)
        icon: mdi-calendar-clock
    - Syncthing:
        href: https://${ingest_syncthing_fqdn}
        description: File sync
        icon: syncthing.svg
