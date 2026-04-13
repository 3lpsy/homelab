events {
  worker_connections 1024;
}
http {
  upstream collabora {
    server localhost:9980;
  }

  map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
  }

  server {
    listen 443 ssl;
    server_name ${server_domain};

    ssl_certificate /etc/nginx/certs/tls.crt;
    ssl_certificate_key /etc/nginx/certs/tls.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    client_max_body_size 0;
    proxy_read_timeout 36000s;

    location ^~ /browser {
      proxy_pass http://collabora;
      proxy_set_header Host $http_host;
    }

    location ^~ /hosting/discovery {
      proxy_pass http://collabora;
      proxy_set_header Host $http_host;
    }

    location ^~ /hosting/capabilities {
      proxy_pass http://collabora;
      proxy_set_header Host $http_host;
    }

    location ^~ /cool/adminws {
      proxy_pass http://collabora;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;
      proxy_set_header Host $http_host;
      proxy_set_header X-Forwarded-Host $host;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_read_timeout 36000s;
      proxy_http_version 1.1;
    }

    location ^~ /cool/convert-to/ {
        proxy_pass http://collabora;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 120s;
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 0;
    }

    location /cool/ {
      proxy_pass http://collabora;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;
      proxy_set_header Host $http_host;
      proxy_set_header X-Forwarded-Host $host;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_read_timeout 36000s;
      proxy_http_version 1.1;
      proxy_buffering off;
      proxy_request_buffering off;
    }
    location /wopi/ {
        proxy_pass http://collabora;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 36000s;
        proxy_buffering off;
        proxy_request_buffering off;
    }


  }
}
