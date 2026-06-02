events {
  worker_connections 1024;
}
http {
  ${nginx_logging_block}

  upstream llama_swap {
    server 127.0.0.1:8080;
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

    # Long-context prompts can be large; generations are slow + streamed.
    client_max_body_size 64M;

    proxy_connect_timeout 600;
    proxy_send_timeout 600;
    # Model swaps block the first request for up to healthCheckTimeout (300s)
    # while the GGUF loads to VRAM, then tokens stream. Keep read timeout well
    # above that so a cold-load request isn't cut off mid-swap.
    proxy_read_timeout 900;
    send_timeout 900;

    location / {
      proxy_pass http://llama_swap;
      proxy_http_version 1.1;
      proxy_set_header Host $http_host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;

      # SSE streaming: disable buffering so tokens flush to the client as they
      # arrive rather than being held by nginx.
      proxy_set_header Connection '';
      proxy_buffering off;
      chunked_transfer_encoding on;
    }
  }
}
