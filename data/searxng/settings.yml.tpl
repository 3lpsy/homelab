use_default_settings:
  engines:
    keep_only:
      - google
      - brave
      - duckduckgo
      - mojeek
      - startpage
      - qwant
      - bing
      - wikipedia
      - github
      - stackoverflow
      - arxiv
      - reddit
      - hackernews

general:
  instance_name: "SearXNG"

server:
  bind_address: "0.0.0.0"
  port: 8080
  # Substituted at container start by the official image entrypoint using
  # the SEARXNG_SECRET env var.
  secret_key: "ultrasecretkey"
  base_url: "https://${searxng_fqdn}/"
  # limiter=false: all traffic arrives via nginx sidecar from same src IP;
  # enabling would rate-limit legitimate internal clients.
  limiter: false
  image_proxy: true
  method: "GET"

search:
  safe_search: 0
  autocomplete: ""
  default_lang: "en"
  formats:
    - html
    - json
  # With per-request proxy rotation, a 429 reflects one Proton IP being hot,
  # not a dead engine. httpx `retries` only covers transport errors, not HTTP
  # 429, so suspension is the only knob for rate-limit recovery. Keep it
  # shorter than typical query cadence so every new search gets another shot
  # via a different proxy.
  suspended_times:
    SearXEngineAccessDenied: 5
    SearXEngineCaptcha: 5
    SearXEngineTooManyRequests: 3
    recoverable: 3

ui:
  static_use_hash: true

# valkey sidecar in same pod — used for rate-limit state, request cache,
# and limiter bot-detection state.
valkey:
  url: valkey://localhost:6379/0

outgoing:
  request_timeout: 4.0
  max_request_timeout: 10.0
  pool_connections: 100
  pool_maxsize: 20
  retries: 5
  enable_http2: true
  # Per-request egress rotation. SearXNG picks one proxy per outbound request
  # and retries others on failure. Each proxy sits in an exit-node pod and
  # tunnels through its own ProtonVPN WireGuard connection, rotating the
  # effective source IP at upstream providers. searxng-ranker reorders this
  # list per cycle based on probe results.
  proxies:
    "all://":
%{ for key in exitnode_keys ~}
      - http://exitnode-${key}-proxy.exitnode.svc.cluster.local:8888
%{ endfor ~}

# Explicit per-engine tuning. Weight biases ranking on tie-break; timeout
# overrides default when engine is known-slow. searxng-ranker injects a
# per-engine `proxies` key at runtime based on probe results.
engines:
  - name: google
    weight: 1.5
    timeout: 5.0
  - name: brave
    weight: 1.4
    timeout: 5.0
  - name: duckduckgo
    weight: 1.3
    timeout: 5.0
  - name: bing
    weight: 1.0
    timeout: 5.0
  - name: mojeek
    weight: 1.0
    timeout: 6.0
  - name: startpage
    weight: 1.0
    timeout: 6.0
  - name: qwant
    weight: 0.9
    timeout: 5.0
  - name: wikipedia
    weight: 1.2
    timeout: 4.0
  - name: github
    weight: 1.0
    timeout: 5.0
  - name: stackoverflow
    weight: 1.0
    timeout: 5.0
  - name: arxiv
    weight: 0.8
    timeout: 6.0
  - name: reddit
    weight: 0.7
    timeout: 5.0
  - name: hackernews
    weight: 0.8
    timeout: 5.0
