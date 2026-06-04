events {
  worker_connections 1024;
}
http {
  ${nginx_logging_block}

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

      # Stream large layer PUTs straight to the registry instead of buffering the
      # whole body in nginx memory first (default proxy_request_buffering=on).
      # Buffering big concurrent blob pushes OOMKilled this 256Mi sidecar, which
      # took the registry endpoint down mid-push (`connection reset`/`refused` on
      # builders). Off = constant low memory regardless of layer size.
      proxy_request_buffering off;
      proxy_http_version 1.1;
      proxy_read_timeout 900s;
      proxy_send_timeout 900s;

      proxy_pass http://registry;
      proxy_set_header Host $http_host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;

      auth_basic           "Docker Registry";
      auth_basic_user_file /etc/nginx/htpasswd;
    }

    location = / {
      return 301 /v2/;
    }
  }
}
