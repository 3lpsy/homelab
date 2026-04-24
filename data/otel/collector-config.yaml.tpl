receivers:
  filelog:
    include:
      - /var/log/pods/*/*/*.log
    start_at: end
    include_file_path: true
    include_file_name: false
    operators:
      - type: container
        id: container-parser

  journald:
    directory: /var/log/journal
    units:
      - k3s.service
      - containerd.service
      - tailscaled.service
      - unattended-upgrades.service
      - sshd.service
      - systemd-journald.service

processors:
  k8sattributes:
    auth_type: serviceAccount
    passthrough: false
    extract:
      metadata:
        - k8s.namespace.name
        - k8s.pod.name
        - k8s.pod.uid
        - k8s.container.name
        - k8s.deployment.name
        - k8s.node.name
      labels:
        - tag_name: app
          key: app
          from: pod
    pod_association:
      - sources:
          - from: resource_attribute
            name: k8s.pod.uid

  resourcedetection/system:
    detectors: [env, system]
    override: false

  resource/host:
    attributes:
      - key: host.role
        value: k3s-node
        action: upsert

  batch:
    timeout: 10s
    send_batch_size: 1024

exporters:
  otlphttp/openobserve:
    endpoint: http://openobserve.${namespace}.svc.cluster.local:5080/api/${openobserve_org}
    headers:
      authorization: "Basic $${env:OO_AUTH}"
    encoding: json
    compression: gzip

extensions:
  health_check:
    endpoint: 0.0.0.0:13133

service:
  extensions: [health_check]
  pipelines:
    logs/pods:
      receivers: [filelog]
      processors: [k8sattributes, resourcedetection/system, batch]
      exporters: [otlphttp/openobserve]
    logs/host:
      receivers: [journald]
      processors: [resourcedetection/system, resource/host, batch]
      exporters: [otlphttp/openobserve]
  telemetry:
    logs:
      level: info
