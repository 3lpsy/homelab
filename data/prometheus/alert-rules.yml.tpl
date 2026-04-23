groups:
  - name: pod-health
    interval: 60s
    rules:
      - alert: PodNotReady
        expr: kube_pod_status_ready{condition="true"} == 0 unless on(pod, namespace) kube_pod_status_phase{phase=~"Succeeded|Failed"} == 1
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} is not ready"

  - name: resource-pressure
    interval: 60s
    rules:
      - alert: ContainerOOMKilled
        expr: |
          increase(kube_pod_container_status_restarts_total[10m]) > 0
            and on(namespace, pod, container)
          kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: "OOMKilled: {{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }})"
          description: "Container exceeded its memory limit and was killed by the cgroup OOM killer."

      # node_vmstat_oom_kill increments on every oom_kill including
      # cgroup-scoped ones, so a per-container OOM double-pages via
      # ContainerOOMKilled. Alert on real node memory pressure instead.
      - alert: NodeMemoryPressure
        expr: node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.05
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Node {{ $labels.instance }} memory pressure"
          description: "Available memory below 5% of total for 5m."
