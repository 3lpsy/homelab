events {
  worker_connections 1024;
}

http {
  # Redacted access log: omit query string so api_key=... is never written to
  # disk. MCP clients may pass the bearer token via ?api_key=... when a header
  # is inconvenient; path + method + status is all we need for ops.
  log_format redacted '$remote_addr - $remote_user [$time_local] '
                      '"$request_method $uri $server_protocol" $status $body_bytes_sent '
                      '"$http_referer" "$http_user_agent"';
  access_log /var/log/nginx/access.log redacted;

  server {
    listen 443 ssl;
    server_name ${server_domain};

    ssl_certificate     /etc/nginx/certs/tls.crt;
    ssl_certificate_key /etc/nginx/certs/tls.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    client_max_body_size 100M;

    proxy_connect_timeout 600;
    proxy_send_timeout    600;
    proxy_read_timeout    600;
    send_timeout          600;

%{ for name, svc in services ~}
    # ${name} — upstream_path=${svc.upstream_path}
    location /${name}/ {
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

      add_header 'Access-Control-Allow-Origin'      $http_origin always;
      add_header 'Access-Control-Allow-Credentials' 'true' always;
      add_header 'Access-Control-Expose-Headers'    'Mcp-Session-Id, Mcp-Protocol-Version' always;

      # upstream_path is where the backend mounts its MCP endpoint.
      # All fastmcp v2 servers here use path="/", so this is "/" today —
      # the variable stays per-service to keep the door open for any
      # future backend that mounts elsewhere.
      proxy_pass http://${name}.mcp.svc.cluster.local:8000${svc.upstream_path};
      proxy_http_version 1.1;
      # Rewrite Host/Origin so each backend's TrustedHostMiddleware (DNS
      # rebinding protection) accepts the request.
      proxy_set_header Host ${name}.mcp.svc.cluster.local:8000;
      proxy_set_header Origin "http://${name}.mcp.svc.cluster.local:8000";
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;

      # Map backend-issued redirects back to the external URL.
      proxy_redirect http://${name}.mcp.svc.cluster.local:8000${svc.upstream_path}  https://$host/${name}/;
      proxy_redirect https://${name}.mcp.svc.cluster.local:8000${svc.upstream_path} https://$host/${name}/;

      # SSE / streamable-http.
      proxy_set_header Connection '';
      proxy_buffering off;
      chunked_transfer_encoding on;
    }

%{ endfor ~}
    location / {
      return 404;
    }
  }
}
