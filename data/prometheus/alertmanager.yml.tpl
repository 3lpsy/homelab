global:
  resolve_timeout: 5m

route:
  receiver: ntfy-bridge
  group_by: ['alertname', 'namespace']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - receiver: ntfy-bridge
      matchers:
        - severity=~".+"
      mute_time_intervals:
        - overnight

receivers:
  - name: ntfy-bridge
    webhook_configs:
      - url: '${bridge_url}'
        send_resolved: true
        http_config:
          basic_auth:
            username: ${ntfy_username}
            password_file: /etc/alertmanager-secrets/ntfy_password

time_intervals:
  - name: overnight
    time_intervals:
      - times:
          - start_time: '00:00'
            end_time: '09:00'
        location: America/Chicago
