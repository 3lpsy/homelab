events {
  worker_connections 1024;
}
http {
  ${nginx_logging_block}

  upstream backend {
    server localhost:${upstream_port};
  }

  # Package tarballs / .crate blobs can be large; don't cap the body.
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

    # Full-path passthrough. Host + X-Forwarded-Proto let the backend
    # (Verdaccio) auto-detect TLS and rewrite tarball dist URLs to the public
    # https host. Verdaccio's reverse-proxy docs specify `Host $host` (port
    # stripped) — not $http_host — for clean tarball URLs. (The crates proxy
    # rewrites download URLs from CRATES_IO_PROXY_URL instead, so the Host
    # value is immaterial to it.)
    location / {
      proxy_pass http://backend;
      proxy_set_header Host              $host;
      proxy_set_header X-Real-IP         $remote_addr;
      proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
    }
  }
}
