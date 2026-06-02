events {
  worker_connections 1024;
}
http {
  ${nginx_logging_block}

  # WebSocket upgrade map: Frigate UI uses WS for live MSE/WebRTC negotiation
  # and event push. Without these the live view stays blank.
  map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
  }

  upstream frigate {
    # Frigate's auth-proxy on 8971 serves HTTPS with a self-signed cert.
    # Frigate's built-in user-password auth is off (auth.enabled: false in
    # config.yml); this port now trusts the X-Forwarded-User /
    # X-Forwarded-Groups headers we set below from the oauth2-proxy
    # auth_request response. proxy_ssl_verify is off in the location
    # blocks because the upstream cert is self-signed and the connection
    # never leaves the pod.
    server localhost:8971;
  }

  server {
    listen 443 ssl;
    http2 on;
    server_name ${server_domain};

    ssl_certificate     /etc/nginx/certs/tls.crt;
    ssl_certificate_key /etc/nginx/certs/tls.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # ─── oauth2-proxy: auth_request subrequest target ────────────────────────
    # nginx hits this on every gated request. oauth2-proxy returns 202 with
    # X-Auth-Request-User / X-Auth-Request-Groups when a session cookie is
    # valid, 401 otherwise — error_page below converts the 401 into a
    # /oauth2/start redirect that kicks off the OIDC code flow.
    location = /oauth2/auth {
      internal;
      proxy_pass       http://127.0.0.1:4180;
      proxy_pass_request_body off;
      proxy_set_header Content-Length "";
      proxy_set_header X-Original-URI $request_uri;
      proxy_set_header Host           $http_host;
      proxy_set_header X-Real-IP      $remote_addr;
      proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
    }

    # ─── oauth2-proxy: public endpoints (start, callback, sign_out) ──────────
    # Browsers reach these directly during the OIDC dance and on logout.
    # Not auth_request-gated — these *are* the auth.
    location /oauth2/ {
      proxy_pass       http://127.0.0.1:4180;
      proxy_set_header Host              $http_host;
      proxy_set_header X-Real-IP         $remote_addr;
      proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Live streams (MSE/HLS) and event API: disable proxy buffering so
    # frames flush immediately, and stretch timeouts well past the default
    # 60s so long-poll WS connections and clip exports don't drop.
    location ~ ^/(live|api|ws|vod)/ {
      auth_request       /oauth2/auth;
      error_page 401 = @oauth2_signin;
      auth_request_set   $auth_user   $upstream_http_x_auth_request_user;
      auth_request_set   $auth_groups $upstream_http_x_auth_request_groups;
      proxy_set_header   X-Forwarded-User   $auth_user;
      proxy_set_header   X-Forwarded-Groups $auth_groups;

      proxy_pass        https://frigate;
      proxy_ssl_verify  off;
      proxy_http_version 1.1;
      proxy_set_header  Upgrade $http_upgrade;
      proxy_set_header  Connection $connection_upgrade;
      proxy_set_header  Host $http_host;
      proxy_set_header  X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header  X-Forwarded-Proto $scheme;
      proxy_set_header  X-Real-IP $remote_addr;
      proxy_buffering   off;
      proxy_request_buffering off;
      proxy_read_timeout  600s;
      proxy_send_timeout  600s;
      send_timeout        600s;
      client_max_body_size 1G;
    }

    location / {
      auth_request       /oauth2/auth;
      error_page 401 = @oauth2_signin;
      auth_request_set   $auth_user   $upstream_http_x_auth_request_user;
      auth_request_set   $auth_groups $upstream_http_x_auth_request_groups;
      proxy_set_header   X-Forwarded-User   $auth_user;
      proxy_set_header   X-Forwarded-Groups $auth_groups;

      proxy_pass        https://frigate;
      proxy_ssl_verify  off;
      proxy_http_version 1.1;
      proxy_set_header  Upgrade $http_upgrade;
      proxy_set_header  Connection $connection_upgrade;
      proxy_set_header  Host $http_host;
      proxy_set_header  X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header  X-Forwarded-Proto $scheme;
      proxy_set_header  X-Real-IP $remote_addr;
      proxy_read_timeout  600s;
      proxy_send_timeout  600s;
      send_timeout        600s;
      client_max_body_size 1G;
    }

    # Named location used by both gated location blocks above. Keeps the
    # `rd=` query arg outside the `error_page` 401 handler so the original
    # URL survives nginx's quoting rules unchanged.
    location @oauth2_signin {
      return 302 /oauth2/start?rd=$scheme://$http_host$request_uri;
    }
  }

  # ─── Internal TLS listener for non-OIDC clients (Home Assistant) ─────────
  # Reachable only via the `frigate-internal` ClusterIP Service on port 443
  # → targetPort 8443. NetworkPolicy scopes inbound to the homeassist
  # namespace; nothing else in the cluster can route to this listener.
  #
  # Reuses the same Let's Encrypt cert as the gated listener above so HA
  # can keep using `https://frigate.<magic>` (resolved via host_aliases on
  # the homeassist pod to this Service's ClusterIP). Backend is Frigate's
  # internal port 5000, which "ignores headers" and treats every request
  # as anonymous-admin per upstream docs — that's the whole point of this
  # path. Auth is enforced exclusively by NetworkPolicy.
  server {
    listen 8443 ssl;
    http2 on;
    server_name ${server_domain};

    ssl_certificate     /etc/nginx/certs/tls.crt;
    ssl_certificate_key /etc/nginx/certs/tls.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    location / {
      proxy_pass        http://localhost:5000;
      proxy_http_version 1.1;
      proxy_set_header  Upgrade $http_upgrade;
      proxy_set_header  Connection $connection_upgrade;
      proxy_set_header  Host $http_host;
      proxy_set_header  X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header  X-Forwarded-Proto $scheme;
      proxy_set_header  X-Real-IP $remote_addr;
      proxy_buffering   off;
      proxy_request_buffering off;
      proxy_read_timeout  600s;
      proxy_send_timeout  600s;
      send_timeout        600s;
      client_max_body_size 1G;
    }
  }
}
