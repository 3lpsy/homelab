events {
  worker_connections 1024;
}
http {
  log_format redacted '$remote_addr - $remote_user [$time_local] '
                      '"$request_method $uri $server_protocol" $status $body_bytes_sent';

  map $http_user_agent $loggable {
    default            1;
    "~*kube-probe/"    0;
  }
  access_log /dev/stdout redacted if=$loggable;
  error_log /dev/stderr warn;

  upstream ingest_app {
    server 127.0.0.1:8000;
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

    # 4 GiB max upload — covers a fat zip of a whole album set.
    client_max_body_size 4096m;

    # Public liveness probe — no auth, no logging.
    location = /healthz {
      auth_basic off;
      proxy_pass http://ingest_app;
      access_log off;
    }

    # Internal pull endpoints used by navidrome-ingest. nginx does NOT
    # apply basic auth here — the FastAPI app validates a Bearer token
    # against /etc/secrets/internal_token. NetworkPolicy is the second
    # gate (only navidrome-ingest pods can reach the internal Service).
    # Long-running file downloads need extended read/send timeouts.
    location /internal/ {
      auth_basic off;
      proxy_pass        http://ingest_app;
      proxy_set_header  Host $host;
      proxy_set_header  X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header  X-Forwarded-Proto $scheme;
      proxy_read_timeout 1800s;
      proxy_send_timeout 1800s;
      proxy_buffering    off;
      client_max_body_size 0;
    }

    # All other endpoints (the form, /api/upload, /api/download, /api/jobs)
    # are auth-gated.
    location / {
      proxy_pass        http://ingest_app;
      proxy_set_header  Host $host;
      proxy_set_header  X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header  X-Forwarded-Proto $scheme;
      proxy_set_header  X-Remote-User $remote_user;
      proxy_read_timeout 1800s;
      proxy_send_timeout 1800s;
      auth_basic           "ingest";
      auth_basic_user_file /etc/nginx/htpasswd;
    }
  }
}
