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

  # Drop the noisiest pod-log sources. Mongo replica-set heartbeat lines
  # survive --quiet, and BuildKit Job pods emit per-step INFO progress that
  # buries any actual build failures. Drop both at the collector so they
  # never reach OO.
  filter/pods_noise:
    error_mode: ignore
    logs:
      log_record:
        # Drop ALL records from the thunderbolt-mongo deployment.
        - resource.attributes["k8s.deployment.name"] == "thunderbolt-mongo"
        # In the builder namespace, keep only records that match an
        # error/warn keyword in the body. Drops INFO/progress lines.
        - resource.attributes["k8s.namespace.name"] == "builder" and not IsMatch(body, "(?i)error|fail|fatal|panic|warn|abort|reject|exception")

  # Journald records arrive with body = map of all journald fields. OO's
  # schema inference doesn't flatten nested map bodies into queryable
  # columns, so we promote the useful fields to attributes (which OO does
  # flatten) and reduce body to the plain MESSAGE string.
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
  otlphttp/pods:
    endpoint: http://openobserve.${namespace}.svc.cluster.local:5080/api/${openobserve_org}
    headers:
      authorization: "Basic $${env:OO_AUTH}"
      stream-name: pods
    encoding: json
    compression: gzip

  otlphttp/k3s_host:
    endpoint: http://openobserve.${namespace}.svc.cluster.local:5080/api/${openobserve_org}
    headers:
      authorization: "Basic $${env:OO_AUTH}"
      stream-name: k3s_host
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
      processors: [k8sattributes, resourcedetection/system, filter/pods_noise, batch]
      exporters: [otlphttp/pods]
    logs/host:
      receivers: [journald]
      processors: [resourcedetection/system, resource/host, transform/journald, batch]
      exporters: [otlphttp/k3s_host]
  telemetry:
    logs:
      level: info
