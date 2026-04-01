events {
  worker_connections 1024;
}
http {
  upstream registry {
    server localhost:5000;
  }

  client_max_body_size 0;
  chunked_transfer_encoding on;

  server {
    listen 443 ssl;
    server_name ${server_domain};

    ssl_certificate     /etc/nginx/certs/tls.crt;
    ssl_certificate_key /etc/nginx/certs/tls.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    location /v2/ {
      client_max_body_size 0;

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
