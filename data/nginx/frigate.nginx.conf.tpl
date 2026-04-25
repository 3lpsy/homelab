events {
  worker_connections 1024;
}
http {
  # Privacy-preserving access log: drops $request_uri (camera names + clip
  # paths can leak occupancy + activity patterns). Keeps method / status /
  # size for liveness debug. Probes filtered out via $loggable.
  log_format redacted '$remote_addr - - [$time_local] '
                      '"$request_method - $server_protocol" $status $body_bytes_sent';

  map $http_user_agent $loggable {
    default            1;
    "~*kube-probe/"    0;
  }
  access_log /dev/stdout redacted if=$loggable;
  error_log /dev/stderr crit;

  # WebSocket upgrade map: Frigate UI uses WS for live MSE/WebRTC negotiation
  # and event push. Without these the live view stays blank.
  map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
  }

  upstream frigate {
    # Frigate's auth-proxy on 8971 serves HTTPS with a self-signed cert.
    # We hit it here (not the unauthenticated 5000 API) so Frigate's
    # built-in user auth is enforced *in addition to* the tailnet ACL.
    # proxy_ssl_verify is off in the location blocks because the upstream
    # cert is self-signed and the connection never leaves the pod.
    server localhost:8971;
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

    # Live streams (MSE/HLS) and event API: disable proxy buffering so
    # frames flush immediately, and stretch timeouts well past the default
    # 60s so long-poll WS connections and clip exports don't drop.
    location ~ ^/(live|api|ws|vod)/ {
      proxy_pass        https://frigate;
      proxy_ssl_verify  off;
      proxy_http_version 1.1;
      proxy_set_header  Upgrade $http_upgrade;
      proxy_set_header  Connection $connection_upgrade;
      proxy_set_header  Host $http_host;
      proxy_set_header  X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header  X-Forwarded-Proto $scheme;
      proxy_set_header  X-Real-IP $remote_addr;
      proxy_buffering   off;
      proxy_request_buffering off;
      proxy_read_timeout  600s;
      proxy_send_timeout  600s;
      send_timeout        600s;
      client_max_body_size 1G;
    }

    location / {
      proxy_pass        https://frigate;
      proxy_ssl_verify  off;
      proxy_http_version 1.1;
      proxy_set_header  Upgrade $http_upgrade;
      proxy_set_header  Connection $connection_upgrade;
      proxy_set_header  Host $http_host;
      proxy_set_header  X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header  X-Forwarded-Proto $scheme;
      proxy_set_header  X-Real-IP $remote_addr;
      proxy_read_timeout  600s;
      proxy_send_timeout  600s;
      send_timeout        600s;
      client_max_body_size 1G;
    }
  }
}
