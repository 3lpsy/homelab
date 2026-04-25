events {
  worker_connections 1024;
}
http {
  log_format redacted '$remote_addr - - [$time_local] '
                      '"$request_method - $server_protocol" $status $body_bytes_sent';

  map $http_user_agent $loggable {
    default            1;
    "~*kube-probe/"    0;
  }
  access_log /dev/stdout redacted if=$loggable;
  error_log /dev/stderr crit;

  # WebSocket upgrade map: Z2M frontend uses WebSocket for live device events.
  map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
  }

  upstream z2m {
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

    location / {
      proxy_pass        http://z2m;
      proxy_http_version 1.1;
      proxy_set_header  Upgrade $http_upgrade;
      proxy_set_header  Connection $connection_upgrade;
      proxy_set_header  Host $http_host;
      proxy_set_header  X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header  X-Forwarded-Proto $scheme;
      proxy_set_header  X-Real-IP $remote_addr;
      proxy_read_timeout 90s;
      proxy_send_timeout 90s;
      auth_basic           "Z2M - Password Required";
      auth_basic_user_file /etc/nginx/htpasswd;
    }
  }
}
