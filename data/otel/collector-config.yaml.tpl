receivers:
  filelog:
    include:
      - /var/log/pods/*/*/*.log
    # Skip the loudest sources at the receiver — never tail the file
    # rather than tail+parse+filter+drop. Mongo replSet heartbeats
    # survive --quiet and dominate the log volume; the matching rule
    # in filter/pods_noise below is the deeper-pipeline equivalent
    # but read+parse cost still falls on filelog. Glob covers all
    # ReplicaSet revisions of the pod.
    exclude:
      - /var/log/pods/thunderbolt_thunderbolt-mongo-*/mongo/*.log
      # halogen (podcasts app) is in active dev at debug level — keep its
      # verbose app logs OUT of OpenObserve (kubectl logs still has them). Only
      # the `podcasts` app container; the `podcasts-nginx` sidecar's JSON access
      # logs still flow for per-service access analytics.
      - /var/log/pods/podcasts_*/podcasts/*.log
    start_at: end
    include_file_path: true
    include_file_name: false
    operators:
      - type: container
        id: container-parser
      # nginx sidecars (services/, vault-conf/zitadel) emit JSON access logs
      # via the shared logging block in `data/nginx/_logging.conf.tpl`.
      # Parse the JSON body so OO indexes status/method/req_time/etc as
      # top-level fields. Container names are inconsistent (some plain
      # `nginx`, others `<svc>-nginx`), so match via regex. The body-shape
      # check skips non-JSON error_log lines that nginx emits to stderr.
      - type: json_parser
        id: nginx-json
        if: 'attributes["k8s.container.name"] matches "^(.+-)?nginx$" && body matches "^\\s*\\{"'
        parse_from: body
        parse_to: attributes
        on_error: send

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

  # In the builder namespace, keep only records that match an
  # error/warn keyword in the body. Drops INFO/progress lines.
  # (Mongo drop moved to filelog.exclude above — handled at receiver
  # so the file is never tailed.)
  filter/pods_noise:
    error_mode: ignore
    logs:
      log_record:
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
