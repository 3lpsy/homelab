events {
  worker_connections 1024;
}
http {
  upstream openobserve {
    server localhost:5080;
  }

  map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
  }

  ${nginx_logging_block}

  # OTLP/HTTP payloads can be sizable; don't clip
  client_max_body_size 100M;

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

    # OpenObserve authenticates every request itself: browser users log
    # in via the SPA (cookie session, ~24h), `/api/*` callers (the
    # off-cluster Headscale otel-collector) carry HTTP basic. nginx is
    # TLS termination only.
    location / {
      proxy_pass http://openobserve;
      proxy_set_header Host $http_host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;

      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;

      proxy_read_timeout 300s;
      proxy_send_timeout 300s;
      proxy_buffering    off;
    }
  }
}
