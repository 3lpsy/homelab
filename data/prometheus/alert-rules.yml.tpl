groups:
  - name: pod-health
    interval: 60s
    rules:
      - alert: PodNotReady
        expr: kube_pod_status_ready{condition="true"} == 0 unless on(pod, namespace) kube_pod_status_phase{phase=~"Succeeded|Failed"} == 1
        for: 3m
        labels:
          severity: warning
        annotations:
          summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} is not ready"
