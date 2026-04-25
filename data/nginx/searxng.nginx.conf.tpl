events {
  worker_connections 1024;
}
http {
  map $http_user_agent $loggable {
    default            1;
    "~*kube-probe/"    0;
  }
  access_log /dev/stdout combined if=$loggable;
  error_log /dev/stderr crit;

  upstream searxng {
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

    client_max_body_size 4M;

    proxy_connect_timeout 60;
    proxy_send_timeout    60;
    proxy_read_timeout    60;
    send_timeout          60;

    location / {
      proxy_pass         http://searxng;
      proxy_http_version 1.1;
      proxy_set_header   Host               $host;
      proxy_set_header   X-Real-IP          $remote_addr;
      proxy_set_header   X-Forwarded-For    $proxy_add_x_forwarded_for;
      proxy_set_header   X-Forwarded-Proto  $scheme;
      proxy_set_header   X-Scheme           $scheme;
      proxy_redirect     off;
    }
  }
}
