events {
  worker_connections 1024;
}
http {
  ${nginx_logging_block}

  # halogen serves its embedded frontend + API on the same port; the player
  # uses streaming responses, so keep the upgrade map for any websocket/SSE.
  map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
  }

  upstream halogen {
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

    # Cover OPML uploads / large episode artwork.
    client_max_body_size 100m;

    location / {
      proxy_pass        http://halogen/;
      proxy_set_header  Host $http_host;
      proxy_set_header  X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header  X-Forwarded-Proto $scheme;
      proxy_set_header  X-Real-IP $remote_addr;

      proxy_http_version 1.1;
      proxy_set_header   Upgrade $http_upgrade;
      proxy_set_header   Connection $connection_upgrade;

      # Episode audio can be large; allow long streamed reads.
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
      proxy_buffering    off;
    }
  }
}
