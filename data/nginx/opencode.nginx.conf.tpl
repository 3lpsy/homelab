events {
  worker_connections 1024;
}
http {
  ${nginx_logging_block}

  # WebSocket / SSE upgrade map. opencode web's SPA holds an SSE long-poll
  # on /global/event; future endpoints may use WS for streaming.
  map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
  }

  upstream opencode {
    server 127.0.0.1:4096;
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

    # ─── oauth2-proxy: auth_request subrequest target ──────────────────────
    # nginx hits this on every gated request. oauth2-proxy returns 202 with
    # X-Auth-Request-User/-Email headers when a session cookie is valid OR
    # when a `Authorization: Bearer <jwt>` header is present and validates
    # against Zitadel (OAUTH2_PROXY_SKIP_JWT_BEARER_TOKENS=true). 401 falls
    # through to the @oauth2_signin redirect.
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
      # Forward Authorization through so oauth2-proxy can validate the
      # bearer JWT path (CLI clients).
      proxy_set_header Authorization $http_authorization;
    }

    # oauth2-proxy public endpoints (start, callback, sign_out). Browsers
    # hit these directly during the OIDC dance — they ARE the auth, so no
    # auth_request gating.
    location /oauth2/ {
      proxy_pass       http://127.0.0.1:4180;
      proxy_set_header Host              $http_host;
      proxy_set_header X-Real-IP         $remote_addr;
      proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
    }

    # SSE event stream. Critical knobs for streaming: proxy_buffering off
    # so frames flush immediately, X-Accel-Buffering: no so any upstream
    # buffering proxy (none today, but defensive) doesn't hold them, long
    # read timeout because the connection stays open until the client goes
    # away.
    location /global/event {
      auth_request       /oauth2/auth;
      error_page 401 = @oauth2_signin;
      auth_request_set   $auth_user  $upstream_http_x_auth_request_user;
      auth_request_set   $auth_email $upstream_http_x_auth_request_email;
      proxy_set_header   X-Forwarded-User   $auth_user;
      proxy_set_header   X-Forwarded-Email  $auth_email;

      proxy_pass         http://opencode;
      proxy_http_version 1.1;
      proxy_set_header   Connection "";
      proxy_set_header   Host              $http_host;
      proxy_set_header   X-Real-IP         $remote_addr;
      proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
      proxy_set_header   X-Forwarded-Proto $scheme;
      proxy_buffering    off;
      proxy_cache        off;
      proxy_read_timeout 24h;
      proxy_send_timeout 24h;
      send_timeout       24h;
      add_header X-Accel-Buffering no always;
    }

    # Browser SPA + REST API + OpenAPI schema. WS upgrade headers carried
    # through for any future opencode endpoint that needs them.
    location / {
      auth_request       /oauth2/auth;
      error_page 401 = @oauth2_signin;
      auth_request_set   $auth_user  $upstream_http_x_auth_request_user;
      auth_request_set   $auth_email $upstream_http_x_auth_request_email;
      proxy_set_header   X-Forwarded-User   $auth_user;
      proxy_set_header   X-Forwarded-Email  $auth_email;

      proxy_pass         http://opencode;
      proxy_http_version 1.1;
      proxy_set_header   Upgrade           $http_upgrade;
      proxy_set_header   Connection        $connection_upgrade;
      proxy_set_header   Host              $http_host;
      proxy_set_header   X-Real-IP         $remote_addr;
      proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
      proxy_set_header   X-Forwarded-Proto $scheme;
      proxy_read_timeout  600s;
      proxy_send_timeout  600s;
      send_timeout        600s;
      client_max_body_size 100M;
    }

    location @oauth2_signin {
      return 302 /oauth2/start?rd=$scheme://$http_host$request_uri;
    }
  }
}
