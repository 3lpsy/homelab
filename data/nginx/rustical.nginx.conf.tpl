events {
  worker_connections 1024;
}
http {
  ${nginx_logging_block}

  upstream rustical {
    server localhost:4000;
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

    # WebDAV verbs need explicit allowlisting; nginx blocks unknown methods
    # by default. PROPFIND/REPORT/MKCALENDAR/etc. are required by CalDAV.
    location / {
      proxy_pass        http://rustical;
      proxy_http_version 1.1;
      proxy_set_header  Host              $http_host;
      proxy_set_header  X-Real-IP         $remote_addr;
      proxy_set_header  X-Forwarded-For   $proxy_add_x_forwarded_for;
      proxy_set_header  X-Forwarded-Proto $scheme;

      proxy_read_timeout  120s;
      proxy_send_timeout  120s;
      client_max_body_size 50m;
    }
  }
}
