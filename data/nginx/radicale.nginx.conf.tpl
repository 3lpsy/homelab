events {
  worker_connections 1024;
}
http {
  # Privacy-preserving access log: drops $remote_user (basic-auth name) and
  # the full request path (which contains calendar+event UUIDs). Keeps just
  # method / static /radicale/ prefix / status / size for liveness debug.
  log_format redacted '$remote_addr - - [$time_local] '
                      '"$request_method /radicale/ $server_protocol" $status $body_bytes_sent';

  map $http_user_agent $loggable {
    default            1;
    "~*kube-probe/"    0;
  }
  access_log /var/log/nginx/access.log redacted if=$loggable;
  error_log /dev/stderr crit;

  upstream radicale {
    server localhost:5232;
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

    location /radicale/ {
      proxy_pass        http://radicale/;
      proxy_set_header  X-Script-Name /radicale;
      proxy_set_header  X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header  X-Forwarded-Proto $scheme;
      proxy_set_header  X-Remote-User $remote_user;
      proxy_set_header  Host $http_host;
      auth_basic           "Radicale - Password Required";
      auth_basic_user_file /etc/nginx/htpasswd;
    }

    location = / {
      return 301 /radicale/;
    }

    location = /.well-known/carddav {
      return 301 /radicale/;
    }

    location = /.well-known/caldav {
      return 301 /radicale/;
    }
  }
}
