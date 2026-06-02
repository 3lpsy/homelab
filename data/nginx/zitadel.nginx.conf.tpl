events {
  worker_connections 1024;
}
http {
  upstream zitadel_api {
    server localhost:8080;
  }
  # Same backend, but reached via grpc_pass for gRPC paths. nginx requires
  # a separate upstream block syntax for grpc_pass.
  upstream zitadel_grpc {
    server localhost:8080;
  }
  upstream zitadel_login {
    server localhost:3000;
  }

  map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
  }

  ${nginx_logging_block}

  # Drop browser-cached basic-auth creds from the public OIDC proxy when
  # they leak onto the tailnet path. Same hostname is reused by the
  # public EC2 nginx and the in-cluster TS sidecar (split-horizon DNS),
  # so the browser caches the proxy's `Basic <user>:...` against the
  # origin and replays it on tailnet token-exchange requests. Zitadel
  # reads `Authorization: Basic` on `/oauth/v2/token` as OAuth
  # client_secret_basic, which 400s the console SPA's PKCE flow and
  # locks the UI in a redirect loop.
  #
  # Discriminator is `Origin`: browsers always send it (CORS), so any
  # browser-issued POST to the token endpoint loses Authorization here.
  # PKCE clients put `client_id` in the form body, so stripping is
  # safe. Confidential server-side OIDC clients (grafana, audiobookshelf,
  # headscale, ...) do not send `Origin` and pass through unchanged with
  # their `Basic <client_id>:<secret>` intact.
  map $http_origin $clean_token_authorization {
    default  $http_authorization;
    "~."     "";
  }

  # OIDC + Zitadel admin UI emit large session/JWT cookies. Bump the proxy
  # header buffer so they don't trigger upstream 502.
  proxy_buffer_size       16k;
  proxy_buffers           8 16k;
  proxy_busy_buffers_size 32k;

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

    # Root → login UI (matches Zitadel v4 traefik example, priority 400).
    location = / {
      return 302 /ui/v2/login;
    }

    # gRPC services — paths starting with `/zitadel.<svc>.v<n>.<Service>/`.
    # Zitadel's REST + console traffic is fine over HTTP/1.1 proxy_pass, but
    # gRPC needs HTTP/2 end-to-end (grpc_pass uses h2c to backend). Without
    # this, the terraform-provider-zitadel data sources fail with
    # "server closed the stream without sending trailers".
    location /zitadel. {
      grpc_pass grpc://zitadel_grpc;
      grpc_set_header Host $http_host;
      grpc_set_header X-Real-IP $remote_addr;
      grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      grpc_set_header X-Forwarded-Proto $scheme;
      grpc_read_timeout  300s;
      grpc_send_timeout  300s;
    }

    # Login UI v2 (Next.js sidecar on :3000). Match WITHOUT trailing slash so
    # both /ui/v2/login and /ui/v2/login/foo route here without nginx auto-301
    # adding a trailing slash (which fights Next.js's NEXT_PUBLIC_BASE_PATH=
    # /ui/v2/login setting that emits 308 back to no-slash → redirect loop).
    location /ui/v2/login {
      proxy_pass http://zitadel_login;
      proxy_http_version 1.1;
      proxy_set_header Host $http_host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;
      proxy_read_timeout  300s;
      proxy_send_timeout  300s;
    }

    # OAuth token endpoint — strip Authorization for browser callers.
    # See the `$clean_token_authorization` map above for rationale.
    # Scoped narrowly so Bearer-authenticated API calls from the SPA
    # (Authorization: Bearer <jwt>) on other paths are untouched.
    location = /oauth/v2/token {
      proxy_pass http://zitadel_api;
      proxy_http_version 1.1;
      proxy_set_header Host $http_host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header Authorization $clean_token_authorization;
      proxy_read_timeout  300s;
      proxy_send_timeout  300s;
    }

    # Everything else → Zitadel core API (console, OIDC, gRPC-Web, etc.)
    location / {
      proxy_pass http://zitadel_api;
      proxy_http_version 1.1;
      proxy_set_header Host $http_host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;
      proxy_read_timeout  300s;
      proxy_send_timeout  300s;
    }
  }
}
