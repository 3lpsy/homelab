log_format json_redacted escape=json
  '{'
    '"time":"$time_iso8601",'
    '"remote_addr":"$remote_addr",'
    '"method":"$request_method",'
    '"protocol":"$server_protocol",'
    '"status":$status,'
    '"bytes_sent":$body_bytes_sent,'
    '"req_time":$request_time,'
    '"up_addr":"$upstream_addr",'
    '"up_status":"$upstream_status",'
    '"up_time":"$upstream_response_time",'
    '"host":"$host",'
    '"ssl_protocol":"$ssl_protocol"'
  '}';

# Two flags get composited into $loggable below:
#   $is_probe         — kube-probe liveness/readiness traffic
#   $is_static_asset  — SPA bundles, fonts, images, source maps. Dropped
#                       by default since they 4-10x access-log volume on
#                       any pod with a frontend (immich, jellyfin, grafana,
#                       openobserve, …) without ops value. Flip
#                       `nginx_log_static_assets = true` to keep them.

map $http_user_agent $is_probe {
  default         0;
  "~*kube-probe/" 1;
}

%{ if log_static_assets ~}
map $uri $is_static_asset {
  default 0;
}
%{ else ~}
map $uri $is_static_asset {
  default                                                                                          0;
  "~*\.(js|mjs|css|svg|png|jpe?g|gif|webp|avif|ico|woff2?|ttf|eot|otf|map|wasm)$"                  1;
}
%{ endif ~}

# Drop the line if either flag is set.
map "$is_probe:$is_static_asset" $loggable {
  "0:0"   1;
  default 0;
}

%{ if access_log_enabled ~}
access_log ${access_log_target} json_redacted if=$loggable;
%{ else ~}
access_log off;
%{ endif ~}
error_log ${error_log_target} ${log_level};
