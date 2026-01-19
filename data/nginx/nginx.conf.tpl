user ${nginx_user};
worker_processes auto;
pid /run/nginx.pid;
# Not on fedora
# include /etc/nginx/modules-enabled/*.conf;
events {
        worker_connections 768;
        # multi_accept on;
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    server_tokens off;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
    gzip on;
    map $http_upgrade $connection_upgrade {
        default      keep-alive;
        'websocket'  upgrade;
        ''           close;
    }
    server {
        listen ${listen_prefix}443      ssl http2;
        # listen [::]:443 ssl http2;
        server_name ${server_domain};
        ssl_certificate /etc/letsencrypt/live/${server_domain}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/${server_domain}/privkey.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        location / {
            proxy_pass ${proxy_proto}://127.0.0.1:${proxy_port};
            %{ if proxy_ssl_verify != "" ~}
             proxy_ssl_verify ${proxy_ssl_verify};
            %{ endif ~}
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host $server_name;
            proxy_redirect http:// https://;
            proxy_buffering off;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
            add_header Strict-Transport-Security "max-age=15552000; includeSubDomains" always;
        }
    }
}
