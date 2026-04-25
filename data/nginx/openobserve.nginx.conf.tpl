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

  # Combined-input map: drop access-log lines for kube-probe health checks
  # AND for SPA static asset GETs (Vue.js bundles under /web/assets and
  # /web/src/assets). Real API requests under /api/ still log normally.
  map "$http_user_agent|$request_uri" $loggable {
    default                       1;
    "~*kube-probe/"               0;
    "~\|/web/assets/"             0;
    "~\|/web/src/assets/"         0;
  }
  access_log /dev/stdout combined if=$loggable;
  error_log /dev/stderr crit;

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
