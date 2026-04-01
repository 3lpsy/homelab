events {
  worker_connections 1024;
}
http {
  access_log /var/log/nginx/access.log;
  error_log /var/log/nginx/error.log;

  upstream nextcloud {
    server localhost:80;
  }

  upstream harp {
    server appapi-harp:8780;
  }

  server {
    listen 443 ssl;
    server_name ${server_domain};

    ssl_certificate /etc/nginx/certs/tls.crt;
    ssl_certificate_key /etc/nginx/certs/tls.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;
    real_ip_header X-Forwarded-For;
    real_ip_recursive on;

    client_max_body_size 20G;
    client_body_buffer_size 16M;

    proxy_connect_timeout 3600;
    proxy_send_timeout 3600;
    proxy_read_timeout 3600;
    send_timeout 3600;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header X-Robots-Tag "noindex, nofollow" always;

    location /exapps/ {
      proxy_pass http://harp;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Forwarded-Host $host;
      proxy_set_header X-Forwarded-Port $server_port;

      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection "upgrade";

      proxy_buffering off;
      proxy_request_buffering off;
    }

    location = /.well-known/carddav {
      return 301 https://$host/remote.php/dav;
    }

    location = /.well-known/caldav {
      return 301 https://$host/remote.php/dav;
    }

    location / {
      proxy_pass http://nextcloud;
      proxy_http_version 1.1;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Forwarded-Host $host;
      proxy_set_header X-Forwarded-Port $server_port;

      proxy_buffering off;
      proxy_request_buffering off;
      proxy_max_temp_file_size 0;
    }
  }
}
