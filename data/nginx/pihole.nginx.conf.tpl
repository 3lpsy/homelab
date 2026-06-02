events {
  worker_connections 1024;
}
http {
  ${nginx_logging_block}

  upstream pihole {
    server localhost:80;
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

    # ─── oauth2-proxy: auth_request subrequest target ──────────────────────────
    # nginx hits this on every gated request. oauth2-proxy returns 202 with
    # X-Auth-Request-User when a session cookie is valid, 401 otherwise —
    # the error_page below converts the 401 into a /oauth2/start redirect that
    # kicks off the OIDC code flow.
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

      proxy_pass http://pihole;
      proxy_set_header Host $http_host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Named location used by the gated location above. Keeps the `rd=` query
    # arg outside the `error_page` 401 handler so the original URL survives
    # nginx's quoting rules unchanged.
    location @oauth2_signin {
      return 302 /oauth2/start?rd=$scheme://$http_host$request_uri;
    }
  }
}
