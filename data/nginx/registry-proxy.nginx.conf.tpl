events {
  worker_connections 1024;
}
http {
  # Drop query args from access log — registry uploads pack `_state=<long
  # signed blob>&digest=<sha>` into every PUT/POST which bloats the log and
  # isn't useful for ops.
  log_format redacted '$remote_addr - $remote_user [$time_local] '
                      '"$request_method $uri $server_protocol" $status $body_bytes_sent '
                      '"$http_referer" "$http_user_agent"';

  map $http_user_agent $loggable {
    default            1;
    "~*kube-probe/"    0;
  }
  access_log /dev/stdout redacted if=$loggable;
  error_log /dev/stderr crit;

  upstream registry {
    server localhost:5000;
  }

  client_max_body_size 0;
  chunked_transfer_encoding on;

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

    location /v2/ {
      client_max_body_size 0;

      proxy_pass http://registry;
      proxy_set_header Host $http_host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      # No auth_basic here — Headscale ACL (group:registry-proxy-clients)
      # is the only access gate. Distribution itself runs in proxy mode
      # which structurally rejects writes, so there's no push surface.
    }

    location = / {
      return 301 /v2/;
    }
  }
}
