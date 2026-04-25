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

  filelog/nginx_access:
    include:
      - /var/log/nginx/access.log
    start_at: end
    include_file_path: true

  filelog/nginx_error:
    include:
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

  # Flatten journald body to a queryable shape — see cluster collector for
  # full rationale.
  transform/journald:
    error_mode: ignore
    log_statements:
      - context: log
        statements:
          - set(attributes["systemd_unit"], body["_SYSTEMD_UNIT"]) where IsMap(body)
          - set(attributes["priority"], body["PRIORITY"]) where IsMap(body)
          - set(attributes["hostname"], body["_HOSTNAME"]) where IsMap(body)
          - set(attributes["pid"], body["_PID"]) where IsMap(body)
          - set(body, body["MESSAGE"]) where IsMap(body)

  batch:
    timeout: 10s
    send_batch_size: 1024

exporters:
  otlphttp/headscale_host:
    endpoint: https://${openobserve_fqdn}/api/${openobserve_org}
    headers:
      authorization: "Basic $${env:OO_AUTH}"
      stream-name: headscale_host
    encoding: json
    compression: gzip

  otlphttp/nginx_access:
    endpoint: https://${openobserve_fqdn}/api/${openobserve_org}
    headers:
      authorization: "Basic $${env:OO_AUTH}"
      stream-name: nginx_access
    encoding: json
    compression: gzip

  otlphttp/nginx_error:
    endpoint: https://${openobserve_fqdn}/api/${openobserve_org}
    headers:
      authorization: "Basic $${env:OO_AUTH}"
      stream-name: nginx_error
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
      processors: [resourcedetection/ec2, resource/host, transform/journald, batch]
      exporters: [otlphttp/headscale_host]
    logs/nginx_access:
      receivers: [filelog/nginx_access]
      processors: [resourcedetection/ec2, resource/host, batch]
      exporters: [otlphttp/nginx_access]
    logs/nginx_error:
      receivers: [filelog/nginx_error]
      processors: [resourcedetection/ec2, resource/host, batch]
      exporters: [otlphttp/nginx_error]
  telemetry:
    logs:
      level: info
