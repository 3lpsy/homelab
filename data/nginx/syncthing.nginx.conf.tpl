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

  # WebSocket upgrade map for Syncthing's GUI event stream.
  map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
  }

  upstream syncthing {
    server 127.0.0.1:8384;
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

    # Syncthing GUI POSTs JSON without limits during folder/device add.
    client_max_body_size 64M;

    location / {
      proxy_pass        http://syncthing;
      proxy_set_header  Host $host;
      proxy_set_header  X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header  X-Forwarded-Proto $scheme;
      proxy_http_version 1.1;
      proxy_set_header  Upgrade $http_upgrade;
      proxy_set_header  Connection $connection_upgrade;
      proxy_read_timeout 600s;
      auth_basic           "Syncthing GUI";
      auth_basic_user_file /etc/nginx/htpasswd;
    }
  }
}
