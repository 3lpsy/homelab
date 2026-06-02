events {
  worker_connections 1024;
}
http {
  ${nginx_logging_block}

  upstream prometheus_upstream {
    server 127.0.0.1:9090;
  }
  upstream alertmanager_upstream {
    server 127.0.0.1:9093;
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

    # Promql payloads can get large on /api/v1/query_range with many series.
    client_max_body_size 16M;

    proxy_connect_timeout 60s;
    proxy_send_timeout    300s;
    proxy_read_timeout    300s;

    # ─── oauth2-proxy: auth_request subrequest target ───────────────────────
    # nginx hits this on every gated request. oauth2-proxy returns 202 with
    # X-Auth-Request-User when a session cookie is valid, 401 otherwise —
    # the named `@oauth2_signin` location below converts the 401 into a
    # /oauth2/start redirect.
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

    # ─── oauth2-proxy: public endpoints (start, callback, sign_out) ─────────
    # Browsers reach these directly during the OIDC code+PKCE dance.
    location /oauth2/ {
      proxy_pass       http://127.0.0.1:4180;
      proxy_set_header Host              $http_host;
      proxy_set_header X-Real-IP         $remote_addr;
      proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
    }

    location @oauth2_signin {
      return 302 /oauth2/start?rd=$scheme://$http_host$request_uri;
    }

    # ─── Landing page ───────────────────────────────────────────────────────
    # Tiny static index served from a ConfigMap. Two big buttons that
    # link into /prometheus/ and /alertmanager/.
    location = / {
      auth_request     /oauth2/auth;
      error_page 401 = @oauth2_signin;

      root /etc/nginx/html;
      try_files /index.html =404;
      default_type text/html;
    }

    # ─── Prometheus UI + API (path-prefixed) ────────────────────────────────
    # Prometheus is started with --web.external-url=https://<fqdn>/prometheus
    # so it serves under /prometheus and emits matching absolute URLs.
    # nginx forwards the prefix as-is — no rewrite/strip.
    location /prometheus/ {
      auth_request     /oauth2/auth;
      error_page 401 = @oauth2_signin;
      auth_request_set $auth_user $upstream_http_x_auth_request_user;
      proxy_set_header X-Forwarded-User $auth_user;

      proxy_pass http://prometheus_upstream;
      proxy_http_version 1.1;
      proxy_set_header Host              $http_host;
      proxy_set_header X-Real-IP         $remote_addr;
      proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header Connection '';
      proxy_buffering off;
    }

    # ─── Alertmanager UI + API (path-prefixed) ──────────────────────────────
    # Same shape as prometheus: --web.external-url=https://<fqdn>/alertmanager
    # so the upstream serves under /alertmanager natively.
    location /alertmanager/ {
      auth_request     /oauth2/auth;
      error_page 401 = @oauth2_signin;
      auth_request_set $auth_user $upstream_http_x_auth_request_user;
      proxy_set_header X-Forwarded-User $auth_user;

      proxy_pass http://alertmanager_upstream;
      proxy_http_version 1.1;
      proxy_set_header Host              $http_host;
      proxy_set_header X-Real-IP         $remote_addr;
      proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header Connection '';
      proxy_buffering off;
    }
  }
}
