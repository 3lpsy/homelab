events {
  worker_connections 1024;
}
http {
  ${nginx_logging_block}

  map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
  }

  upstream pdf {
    server localhost:8080;
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

    # Stirling-PDF accepts large uploads + multi-file merges.
    client_max_body_size 500m;

    # ─── oauth2-proxy: auth_request subrequest target ──────────────────────────
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

      proxy_pass         http://pdf;
      proxy_set_header   Host $http_host;
      proxy_set_header   X-Real-IP $remote_addr;
      proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header   X-Forwarded-Proto $scheme;

      proxy_http_version 1.1;
      proxy_set_header   Upgrade $http_upgrade;
      proxy_set_header   Connection $connection_upgrade;

      # OCR + LibreOffice conversion of big PDFs can run minutes.
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
    }

    location @oauth2_signin {
      return 302 /oauth2/start?rd=$scheme://$http_host$request_uri;
    }
  }
}
