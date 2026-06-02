events {
  worker_connections 1024;
}
http {
  upstream headlamp {
    server localhost:4466;
  }

  map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
  }

  ${nginx_logging_block}

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

    # ─── oauth2-proxy: auth_request subrequest target ──────────────────────────
    # nginx hits this on every gated request. oauth2-proxy returns 202 on a
    # valid session, 401 otherwise — error_page below redirects 401s into
    # /oauth2/start to kick off the OIDC code flow.
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

    # ─── oauth2-proxy: public endpoints (start, callback, sign_out) ────────────
    # Browsers reach these directly during the OIDC dance. Not auth_request-gated.
    location /oauth2/ {
      proxy_pass       http://127.0.0.1:4180;
      proxy_set_header Host              $http_host;
      proxy_set_header X-Real-IP         $remote_addr;
      proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
      auth_request       /oauth2/auth;
      error_page 401 = @oauth2_signin;
      auth_request_set   $auth_user $upstream_http_x_auth_request_user;
      proxy_set_header   X-Forwarded-User $auth_user;

      # Inject the headlamp-auth cookie carrying the SA's long-lived
      # token. Headlamp's proxy reads this cookie (per cookies.go's
      # GetTokenFromCookie) and uses it as the Bearer to apiserver. The
      # browser never sees this cookie. The placeholder is substituted
      # at startup by the inject-sa-token init container.
      proxy_set_header Cookie "headlamp-auth-main.0=__HEADLAMP_SA_TOKEN__; $http_cookie";

      proxy_pass http://headlamp;
      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;
      proxy_set_header Host $http_host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_read_timeout 3600s;
      proxy_send_timeout 3600s;
    }

    # Named location preserves the original `?rd=…` query string through the
    # 401 → 302 hop.
    location @oauth2_signin {
      return 302 /oauth2/start?rd=$scheme://$http_host$request_uri;
    }
  }
}
