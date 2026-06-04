events {
  worker_connections 1024;
}
http {
  ${nginx_logging_block}

  # Cache backend responses. The backend (Verdaccio / chilled-crates) is
  # single-threaded and the cooldown filter re-serializes every packument per
  # request, so it can't keep up with a parallel `bun install`. Caching at nginx:
  #   - proxy_cache_lock: collapse concurrent identical requests into ONE backend
  #     fetch (the rest wait for it) instead of all hammering the single thread;
  #   - proxy_cache_use_stale: if the backend briefly chokes/times out, serve the
  #     last-good copy instead of failing the client's install.
  # The 7-day cooldown is untouched: the backend still applies the delay-filter on
  # every cache MISS/refresh; nginx only absorbs bursty duplicate + while-busy
  # reads with a short TTL. Accept is in the cache key because the backend varies
  # metadata format (abbreviated vs full) by Accept header.
  proxy_cache_path /var/cache/nginx/pkgproxy levels=1:2 keys_zone=pkgproxy:20m
                   max_size=4g inactive=2h use_temp_path=off;

  upstream backend {
    server localhost:${upstream_port};
  }

  # Package tarballs / .crate blobs can be large; don't cap the body.
  client_max_body_size 0;
  chunked_transfer_encoding on;

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

    # Full-path passthrough. Host + X-Forwarded-Proto let the backend
    # (Verdaccio) auto-detect TLS and rewrite tarball dist URLs to the public
    # https host. Verdaccio's reverse-proxy docs specify `Host $host` (port
    # stripped) — not $http_host — for clean tarball URLs. (The crates proxy
    # rewrites download URLs from CRATES_IO_PROXY_URL instead, so the Host
    # value is immaterial to it.)
    location / {
      proxy_pass http://backend;
      proxy_set_header Host              $host;
      proxy_set_header X-Real-IP         $remote_addr;
      proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;

      # Coalesce + serve-stale (see proxy_cache_path note above). This, not retry,
      # is what protects the single-threaded backend. Short metadata TTL preserves
      # the cooldown; tarballs are immutable so the TTL is harmless to them.
      proxy_cache                  pkgproxy;
      proxy_cache_key              "$scheme$request_method$host$request_uri$http_accept";
      proxy_cache_valid            200 301 302 10m;
      proxy_cache_valid            404 1m;
      proxy_cache_lock             on;
      proxy_cache_lock_timeout     120s;
      proxy_cache_use_stale        error timeout updating http_500 http_502 http_503 http_504;
      proxy_cache_background_update on;
      add_header X-Cache-Status    $upstream_cache_status always;

      # Retry only FAST hard failures (connection refused / 502 / 503). NOT
      # `timeout`: retrying a slow request just doubles load on the one backend
      # thread (the bug in the previous config). Modest read timeout — the bun
      # client-side --network-concurrency throttle keeps per-request latency low.
      proxy_next_upstream    error http_502 http_503;
      proxy_connect_timeout  10s;
      proxy_read_timeout     120s;
      proxy_send_timeout     120s;
    }
  }
}
