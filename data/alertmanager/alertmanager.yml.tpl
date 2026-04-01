global:
  resolve_timeout: 5m

route:
  receiver: ntfy
  group_by: ['alertname', 'namespace']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - receiver: ntfy
      matchers:
        - severity=~".+"
      mute_time_intervals:
        - overnight

receivers:
  - name: ntfy
    webhook_configs:
      - url: '${ntfy_url}/${ntfy_topic}'
        send_resolved: true
        http_config:
          basic_auth:
            username: prometheus
            password: '${ntfy_password}'

time_intervals:
  - name: overnight
    time_intervals:
      - times:
          - start_time: '00:00'
            end_time: '09:00'
        location: America/Chicago
