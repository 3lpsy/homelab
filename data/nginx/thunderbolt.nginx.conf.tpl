events {
  worker_connections 1024;
}

http {
  # Redacted access log. Drops:
  #   - query string (so ?client_id=<uuid> on powersync endpoints is gone)
  #   - path segment on /v1/pro/link-preview/<URL-ENCODED-URL>/... since that
  #     reveals which links the user is viewing.
  map $uri $logged_uri {
    default                        $uri;
    "~^/v1/pro/link-preview/"      /v1/pro/link-preview/REDACTED;
  }
  log_format redacted '$remote_addr - $remote_user [$time_local] '
                      '"$request_method $logged_uri $server_protocol" $status $body_bytes_sent '
                      '"$http_referer" "$http_user_agent"';

  map $http_user_agent $loggable {
    default            1;
    "~*kube-probe/"    0;
  }
  access_log /var/log/nginx/access.log redacted if=$loggable;
  error_log /dev/stderr crit;

  upstream thunderbolt_frontend  { server 127.0.0.1:80; }
  upstream thunderbolt_backend   { server thunderbolt-backend.thunderbolt.svc.cluster.local:8000; }
  upstream thunderbolt_powersync { server thunderbolt-powersync.thunderbolt.svc.cluster.local:8080; }
  upstream thunderbolt_keycloak  { server thunderbolt-keycloak.thunderbolt.svc.cluster.local:8080; }

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
    # COOP + COEP are owned by the inner frontend nginx (matches upstream
    # thunderbolt config: data/images/thunderbolt/frontend/nginx.conf). Setting
    # them here too produces duplicate headers, which strict parsers (Firefox)
    # treat as invalid → crossOriginIsolated becomes false → PowerSync WASQLite
    # sqlite3_open_v2 fails.
    # CORP on the sidecar is fine — it applies to proxied /v1/, /powersync/,
    # /realms/ responses so they can be fetched from the isolated document.
    add_header Cross-Origin-Resource-Policy "same-origin" always;

    client_max_body_size 100M;

    proxy_connect_timeout 600;
    proxy_send_timeout    600;
    proxy_read_timeout    600;
    send_timeout          600;

    # Backend API
    location ^~ /v1/ {
      proxy_pass http://thunderbolt_backend;
      proxy_http_version 1.1;
      proxy_set_header Host $http_host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection "upgrade";
      proxy_buffering off;
      chunked_transfer_encoding on;
    }

    # PowerSync
    # Trailing slash on proxy_pass strips the /powersync/ prefix before
    # forwarding — journeyapps/powersync-service serves /sync/stream at root
    # and has no base_path option, so the SDK's /powersync/sync/stream must
    # arrive upstream as /sync/stream.
    location ^~ /powersync/ {
      proxy_pass http://thunderbolt_powersync/;
      proxy_http_version 1.1;
      proxy_set_header Host $http_host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header Connection '';
      proxy_buffering off;
      chunked_transfer_encoding on;
    }

    # Keycloak (OIDC + admin console)
    location ~ ^/(realms|admin|resources|js|robots\.txt) {
      proxy_pass http://thunderbolt_keycloak;
      proxy_http_version 1.1;
      proxy_set_header Host $http_host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Block source maps
    location ~* \.map$ {
      return 404;
    }

    # Better-auth fallback: server-side basePath defaults to `/api/auth`
    # (no override in upstream), so its error/success redirects land
    # outside the /v1 prefix. Rewrite to /v1/api/auth/* so the backend
    # renders something instead of SPA index.html.
    location ^~ /api/auth/ {
      rewrite ^/api/auth/(.*) /v1/api/auth/$1 break;
      proxy_pass http://thunderbolt_backend;
      proxy_http_version 1.1;
      proxy_set_header Host $http_host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
    }

    # SPA (frontend container)
    location / {
      proxy_pass http://thunderbolt_frontend;
      proxy_http_version 1.1;
      proxy_set_header Host $http_host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
    }
  }
}
