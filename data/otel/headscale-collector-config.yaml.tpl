receivers:
  journald:
    directory: /var/log/journal
    units:
      - headscale.service
      - nginx.service
      - tailscaled.service
      - ssh.service
      - systemd-journald.service
      - unattended-upgrades.service

  filelog/nginx:
    include:
      - /var/log/nginx/access.log
      - /var/log/nginx/error.log
    start_at: end
    include_file_path: true

processors:
  resourcedetection/ec2:
    detectors: [env, ec2]
    override: false

  resource/host:
    attributes:
      - key: host.role
        value: headscale
        action: upsert

  batch:
    timeout: 10s
    send_batch_size: 1024

exporters:
  otlphttp/openobserve:
    endpoint: https://${openobserve_fqdn}/api/${openobserve_org}
    headers:
      authorization: "Basic $${env:OO_AUTH}"
    encoding: json
    compression: gzip

extensions:
  health_check:
    endpoint: 127.0.0.1:13133

service:
  extensions: [health_check]
  pipelines:
    logs/journald:
      receivers: [journald]
      processors: [resourcedetection/ec2, resource/host, batch]
      exporters: [otlphttp/openobserve]
    logs/nginx:
      receivers: [filelog/nginx]
      processors: [resourcedetection/ec2, resource/host, batch]
      exporters: [otlphttp/openobserve]
  telemetry:
    logs:
      level: info
