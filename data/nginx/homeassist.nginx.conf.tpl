events {
  worker_connections 1024;
}
http {
  # Privacy-preserving access log: drops $request_uri (Home Assistant URLs
  # can leak entity ids and dashboard names). Keeps method / status / size
  # for liveness debug. Probes filtered out via $loggable.
  log_format redacted '$remote_addr - - [$time_local] '
                      '"$request_method - $server_protocol" $status $body_bytes_sent';

  map $http_user_agent $loggable {
    default            1;
    "~*kube-probe/"    0;
  }
  access_log /dev/stdout redacted if=$loggable;
  error_log /dev/stderr crit;

  # WebSocket upgrade map: when client requests Upgrade, forward it; otherwise
  # leave Connection alone so HTTP/1.1 keep-alive works as expected.
  map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
  }

  upstream homeassist {
    server localhost:8123;
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

    # Home Assistant frontend uses WebSocket heavily for live state updates.
    # Without these proxy_set_header lines the dashboard goes stale and the
    # mobile app login fails.
    location / {
      proxy_pass        http://homeassist;
      proxy_http_version 1.1;
      proxy_set_header  Upgrade $http_upgrade;
      proxy_set_header  Connection $connection_upgrade;
      proxy_set_header  Host $http_host;
      proxy_set_header  X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header  X-Forwarded-Proto $scheme;
      proxy_set_header  X-Real-IP $remote_addr;
      proxy_read_timeout  90s;
      proxy_send_timeout  90s;
      client_max_body_size 100M;
    }
  }
}
