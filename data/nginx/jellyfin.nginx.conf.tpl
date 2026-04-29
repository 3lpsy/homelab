events {
  worker_connections 1024;
}
http {
  log_format redacted '$remote_addr - - [$time_local] '
                      '"$request_method $uri $server_protocol" $status $body_bytes_sent';

  map $http_user_agent $loggable {
    default            1;
    "~*kube-probe/"    0;
  }
  access_log /dev/stdout redacted if=$loggable;
  error_log /dev/stderr crit;

  map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
  }

  upstream jellyfin {
    server localhost:8096;
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

    # Jellyfin streams large transcoded responses; allow big uploads (cover
    # art, plugin packages) and long-lived stream connections.
    client_max_body_size 200m;

    location / {
      proxy_pass        http://jellyfin/;
      proxy_set_header  Host $http_host;
      proxy_set_header  X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header  X-Forwarded-Proto $scheme;
      proxy_set_header  X-Real-IP $remote_addr;

      proxy_http_version 1.1;
      proxy_set_header   Upgrade $http_upgrade;
      proxy_set_header   Connection $connection_upgrade;

      # Long timeouts for active playback sessions and live progress events.
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
      proxy_buffering    off;
    }
  }
}
