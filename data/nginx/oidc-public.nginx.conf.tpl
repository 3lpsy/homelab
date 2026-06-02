# Public reverse proxy on the headscale EC2 for the in-cluster Zitadel
# OIDC server. Same hostname as the in-cluster TS sidecar
# (`oidc.<magic_domain>`) — split-horizon DNS sends off-tailnet clients
# here, on-tailnet clients still hit the in-cluster TS IP via MagicDNS.
# Issuer URL stays byte-identical, so existing OIDC consumers (grafana,
# audiobookshelf, homeassist, rustical) are untouched.
#
# Browser flow for headscale OIDC sign-in from off-tailnet:
#   1. browser hits headscale at /oidc/login, gets 302 to authorize URL
#   2. browser hits this vhost at /oauth/v2/authorize?...
#   3. nginx HTTP basic auth challenge — user types proxy user +
#      passphrase, nginx proxies to in-cluster Zitadel TS IP via MagicDNS
#   4. Zitadel login UI — user enters Zitadel creds, success
#   5. redirect chain back to headscale's /oidc/callback off-proxy;
#      headscale-Zitadel token exchange happens server-side over the
#      tailnet, bypasses this proxy entirely
#
# Basic auth covers all of `/`. No carve-out for /.well-known or /jwks
# because the only client that needs unauth discovery is headscale
# itself, and headscale on this EC2 reaches Zitadel directly over the
# tailnet (MagicDNS resolves oidc.<magic> to the in-cluster TS IP, not
# this proxy).
server {
    listen 443 ssl http2;
    server_name ${oidc_fqdn};

    ssl_certificate /etc/letsencrypt/live/${oidc_fqdn}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${oidc_fqdn}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    # Slow-loris / hung-connection defense. Tighter than nginx defaults
    # (60s across the board) since this is interactive auth — anything
    # that takes >10s to send a request body or header is broken or
    # malicious. Doesn't affect legit logins, which complete sub-second.
    # No rate-limit zone here — Zitadel's SPA bursts ~10-20 asset GETs
    # on first paint and would be brittle under a tight bucket. Bcrypt
    # cost on basic-auth is already a natural ~20/s/CPU brute-force cap.
    client_body_timeout   10s;
    client_header_timeout 10s;
    send_timeout          10s;
    keepalive_timeout     30s;

    # Force MagicDNS resolution for the upstream — using a variable in
    # proxy_pass disables nginx's startup-time hostname caching and makes
    # it re-resolve via the `resolver` directive on each request. Without
    # this, if the EC2 ever queried public DNS for ${oidc_fqdn} (which
    # answers with the EC2's own public IP), nginx would loop back into
    # itself. 100.100.100.100 is Tailscale's MagicDNS server, available
    # to this host because tailscaled is up with --accept-dns.
    resolver 100.100.100.100 valid=30s ipv6=off;

    location / {
        auth_basic "Homelab OIDC";
        auth_basic_user_file /etc/nginx/oidc-public.htpasswd;

        # Upstream timeouts to in-cluster Zitadel via tailnet. 5s connect
        # is generous (tailnet is sub-100ms in steady state); 30s send/read
        # covers Zitadel's slow paths (cold DB connection, first JWT issue).
        proxy_connect_timeout 5s;
        proxy_send_timeout    30s;
        proxy_read_timeout    30s;

        set $upstream_oidc ${oidc_fqdn};
        proxy_pass https://$upstream_oidc;

        proxy_ssl_server_name on;
        proxy_ssl_name ${oidc_fqdn};
        proxy_set_header Host ${oidc_fqdn};

        # Strip the basic-auth header after this proxy validates it. Same
        # hostname is reused by the in-cluster TS sidecar over MagicDNS, so
        # browsers cache the basic creds against the origin and replay them
        # on the tailnet path too. Upstream Zitadel reads `Authorization:
        # Basic` as OAuth client_secret_basic and 400s the token endpoint
        # when the cached proxy creds collide with the console's PKCE flow.
        proxy_set_header Authorization "";

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        proxy_redirect http:// https://;

        add_header Strict-Transport-Security "max-age=15552000; includeSubDomains" always;
    }
}
