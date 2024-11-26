---
server_url: https://${server_domain}:443
listen_addr: 127.0.0.1:${server_port}
metrics_listen_addr: 127.0.0.1:9090
# remote cli access
grpc_listen_addr: 127.0.0.1:50443
grpc_allow_insecure: false
noise:
  private_key_path: /var/lib/headscale/noise_private.key

# default tailscale Ips to allocate
prefixes:
  v6: fd7a:115c:a1e0::/48
  v4: 100.64.0.0/10
  # other option random
  allocation: sequential
# headscale needs a list of DERP servers that can be presented
# to the clients.
# Disabled embedded derp / using tailscale derps
derp:
  server:
    enabled: false
    region_id: 999
    region_code: "headscale"
    region_name: "Headscale Embedded DERP"
    stun_listen_addr: "0.0.0.0:3478"
    private_key_path: /var/lib/headscale/derp_server_private.key
    automatically_add_embedded_derp_region: true
    ipv4: 1.2.3.4
    ipv6: 2001:db8::1
  # List of externally available DERP maps encoded in JSON
  urls:
    - https://controlplane.tailscale.com/derpmap/default

  # For hosting own derp server
  # paths:
  #   - /etc/headscale/derp-example.yaml
  paths: []
  # If enabled, a worker will be set up to periodically
  # refresh the given sources and update the derpmap
  # will be set up.
  auto_update_enabled: true
  # How often should we check for DERP updates?
  update_frequency: 24h
disable_check_updates: false
ephemeral_node_inactivity_timeout: 30m
database:
  type: sqlite
  debug: false
  gorm:
    prepare_stmt: true
    parameterized_queries: true
    skip_err_record_not_found: true
    slow_threshold: 1000
  sqlite:
    path: /var/lib/headscale/db.sqlite
    write_ahead_log: true

  # Removed postgres config as using sqlite
# Removed TLS/Acme section as using Route53 Acme
## Use already defined certificates:
tls_cert_path: "/etc/letsencrypt/live/hs.fgsci.net/fullchain.pem"
tls_key_path: "/etc/letsencrypt/live/hs.fgsci.net/privkey.pem"
log:
  format: text
  level: info

## Policy
# headscale supports Tailscale's ACL policies.
# Please have a look to their KB to better
# understand the concepts: https://tailscale.com/kb/1018/acls/
policy:
  # The mode can be "file" or "database" that defines
  # where the ACL policies are stored and read from.
  mode: file
  # If the mode is set to "file", the path to a
  # HuJSON file containing ACL policies.
  path: "/etc/headscale/acls.hjson"

## DNS
dns:
  magic_dns: true
  base_domain: ${magic_domain}

  # List of DNS servers to expose to clients.
  nameservers:
    global:
      - 9.9.9.9
      - 149.112.112.112
      - 2620:fe::fe
      - 2620:fe::9
    split:
      {}
  # Set custom DNS search domains. With MagicDNS enabled,
  # your tailnet base_domain is always the first search domain.
  search_domains: []
  extra_records: []

# Unix socket used for the CLI to connect without authentication
# Note: for production you will want to set this to something like:
unix_socket: /var/run/headscale/headscale.sock
unix_socket_permission: "0770"
logtail:
  # disabled by default. Enabling this will make your clients send logs to Tailscale Inc.
  enabled: false
randomize_client_port: false
