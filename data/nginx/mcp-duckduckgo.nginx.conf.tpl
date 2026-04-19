events {
  worker_connections 1024;
}

http {
  upstream mcp_backend {
    server 127.0.0.1:8000;
  }

  server {
    listen 443 ssl;
    server_name ${server_domain};

    ssl_certificate     /etc/nginx/certs/tls.crt;
    ssl_certificate_key /etc/nginx/certs/tls.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    client_max_body_size 16M;

    proxy_connect_timeout 600;
    proxy_send_timeout    600;
    proxy_read_timeout    600;
    send_timeout          600;

    # MCP endpoint — strip /public/mcp-duckduckgo/ prefix, forward to local FastMCP.
    # Host rewritten to 127.0.0.1 — the MCP Python SDK's streamable-http server
    # uses Starlette TrustedHostMiddleware (DNS rebinding protection) and only
    # trusts localhost by default.
    location ${path_prefix}/ {
      # CORS preflight
      if ($request_method = OPTIONS) {
        add_header 'Access-Control-Allow-Origin'      $http_origin always;
        add_header 'Access-Control-Allow-Credentials' 'true' always;
        add_header 'Access-Control-Allow-Methods'     'GET, POST, OPTIONS, DELETE' always;
        add_header 'Access-Control-Allow-Headers'     'Content-Type, Accept, Authorization, Mcp-Session-Id, Mcp-Protocol-Version, Last-Event-ID' always;
        add_header 'Access-Control-Max-Age'           1728000;
        add_header 'Content-Length'                   0;
        add_header 'Content-Type'                     'text/plain; charset=UTF-8';
        return 204;
      }

      # CORS on actual responses
      add_header 'Access-Control-Allow-Origin'      $http_origin always;
      add_header 'Access-Control-Allow-Credentials' 'true' always;
      add_header 'Access-Control-Expose-Headers'    'Mcp-Session-Id, Mcp-Protocol-Version' always;

      proxy_pass http://mcp_backend/;
      proxy_http_version 1.1;
      proxy_set_header Host 127.0.0.1:8000;
      # MCP SDK also validates the Origin header (DNS rebinding). Rewrite to a
      # trusted value so browser-originated requests from other tailnet FQDNs
      proxy_set_header Origin "http://127.0.0.1:8000";
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;

      # SSE / streamable-http
      proxy_set_header Connection '';
      proxy_buffering off;
      chunked_transfer_encoding on;
    }

    location / {
      return 404;
    }
  }
}
