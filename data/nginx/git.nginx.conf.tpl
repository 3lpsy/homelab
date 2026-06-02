events {
  worker_connections 1024;
}
http {
  ${nginx_logging_block}

  upstream forgejo {
    server localhost:3000;
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

    # Git HTTP pushes of large objects (LFS off, but bare git can still
    # push multi-hundred-MB packs). Bumped well above the rustical 50m
    # default. Tune up further if `git push` rejects with 413.
    client_max_body_size 512m;

    location / {
      proxy_pass        http://forgejo;
      proxy_http_version 1.1;
      proxy_set_header  Host              $http_host;
      proxy_set_header  X-Real-IP         $remote_addr;
      proxy_set_header  X-Forwarded-For   $proxy_add_x_forwarded_for;
      proxy_set_header  X-Forwarded-Proto $scheme;

      # Long-running clones / pushes shouldn't trip nginx's default 60s.
      proxy_read_timeout  600s;
      proxy_send_timeout  600s;
    }
  }
}
