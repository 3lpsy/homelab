# AMD GPU metrics exporter (observability for artemis's 2× R9700).
#
# The ROCm device-metrics-exporter reads per-GPU telemetry (utilisation,
# VRAM, temperature, power, clocks) via amd-smi over /dev/kfd + /dev/dri and
# exposes it as Prometheus metrics on :5000/metrics. It complements
# `services/amd-gpu-plugin.tf` — the device plugin only advertises the
# `amd.com/gpu` resource and ships no metrics (we deliberately chose the
# lightweight plugin over the metrics-bundled AMD GPU Operator; see
# docs/CLUSTER_SECONDARY_NODE.md "AMD GPU exposure").
#
# Pinned to artemis: same nodeSelector + gpu toleration as the device plugin —
# delphi has no discrete AMD GPU.
#
# Scrape path: pod carries prometheus.io/* annotations so the existing
# `kubernetes-pods` job in data/prometheus/prometheus.yml.tpl picks it up. That
# job needs a netpol path on BOTH ends because Prometheus egress is a strict
# allow-list that excludes the pod CIDR — the ingress allow lives here
# (`gpu-metrics-from-prometheus`), the mirror egress in services/prometheus.tf
# (`prometheus-to-gpu-metrics`).
#
# Privileged: required, not optional. A non-privileged container's device
# cgroup denies /dev/kfd ioctls even with the node bind-mounted — only
# `privileged` (or a real amd.com/gpu device-plugin allocation, which would
# reserve a WHOLE GPU and starve inference) grants the access amd-smi needs.
# AMD's own docs confirm /dev/kfd needs privileged. The exporter reads
# telemetry for all GPUs without consuming an `amd.com/gpu` count.

# The exporter auto-detects in-cluster mode (kubelet injects KUBERNETES_SERVICE_*
# into every pod) and creates an API client to associate GPUs → pods/nodes. It
# FATALS at startup without a SA token, so it needs a ServiceAccount + read-only
# pod/node RBAC (cluster-wide: GPU consumer pods can live in any namespace).
resource "kubernetes_service_account" "amd_gpu_metrics_exporter" {
  metadata {
    name      = "amd-gpu-metrics-exporter"
    namespace = kubernetes_namespace.amd_gpu.metadata[0].name
  }
}

resource "kubernetes_cluster_role" "amd_gpu_metrics_exporter" {
  metadata {
    name = "amd-gpu-metrics-exporter"
  }
  rule {
    api_groups = [""]
    resources  = ["pods", "nodes"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "amd_gpu_metrics_exporter" {
  metadata {
    name = "amd-gpu-metrics-exporter"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.amd_gpu_metrics_exporter.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.amd_gpu_metrics_exporter.metadata[0].name
    namespace = kubernetes_namespace.amd_gpu.metadata[0].name
  }
}

resource "kubernetes_daemonset" "amd_gpu_metrics_exporter" {
  metadata {
    name      = "amd-gpu-metrics-exporter"
    namespace = kubernetes_namespace.amd_gpu.metadata[0].name
    labels    = { app = "amd-gpu-metrics-exporter" }
  }

  spec {
    selector {
      match_labels = { app = "amd-gpu-metrics-exporter" }
    }

    template {
      metadata {
        labels = { app = "amd-gpu-metrics-exporter" }
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "5000"
          "prometheus.io/path"   = "/metrics"
        }
      }

      spec {
        # k8s-mode exporter needs its SA token to build the API client (see
        # the ServiceAccount/RBAC above) — without it the container fatals.
        # API egress is opened by `gpu-metrics-to-kube-api` (the amd-gpu
        # baseline denies API egress by default).
        service_account_name            = kubernetes_service_account.amd_gpu_metrics_exporter.metadata[0].name
        automount_service_account_token = true

        # Only artemis has the GPUs + ROCm driver. Taint repels everything
        # without a gpu toleration; the nodeSelector keeps it off delphi.
        node_selector = { node = "artemis" }

        toleration {
          key      = "gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        container {
          name              = "amd-gpu-metrics-exporter"
          image             = var.image_amd_gpu_metrics_exporter
          image_pull_policy = "Always"

          port {
            name           = "metrics"
            container_port = 5000
          }

          # root + privileged: needed for the device cgroup to permit /dev/kfd
          # ioctls (see file header). renderD* nodes are root:render 0660.
          security_context {
            privileged = true
            run_as_user = 0
          }

          # Device nodes amd-smi opens to enumerate + poll the GPUs.
          volume_mount {
            name       = "kfd"
            mount_path = "/dev/kfd"
          }
          volume_mount {
            name       = "dri"
            mount_path = "/dev/dri"
          }

          resources {
            requests = { cpu = "25m", memory = "64Mi" }
            limits   = { cpu = "250m", memory = "256Mi" }
          }
        }

        volume {
          name = "kfd"
          host_path {
            path = "/dev/kfd"
            type = "CharDevice"
          }
        }
        volume {
          name = "dri"
          host_path {
            path = "/dev/dri"
            type = "Directory"
          }
        }
      }
    }
  }
}

# Egress allow: exporter → kube-apiserver :6443. The exporter's k8s client
# (GPU→pod mapping) needs the API; the amd-gpu netpol-baseline sets
# allow_kube_api_egress=false, so scope an allow to just this pod rather than
# opening API egress for the whole ns (incl. the device plugin). kube-proxy
# DNATs kubernetes.default.svc:443 to the node IP:6443, so allow via ipBlock
# excluding the cluster CIDRs (mirrors the baseline's API-egress shape).
resource "kubernetes_network_policy" "gpu_metrics_to_kube_api" {
  metadata {
    name      = "gpu-metrics-to-kube-api"
    namespace = kubernetes_namespace.amd_gpu.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { app = "amd-gpu-metrics-exporter" }
    }
    policy_types = ["Egress"]

    egress {
      to {
        ip_block {
          cidr = "0.0.0.0/0"
          except = [
            var.k8s_pod_cidr,
            var.k8s_service_cidr,
          ]
        }
      }
      ports {
        protocol = "TCP"
        port     = "6443"
      }
    }
  }
}

# Ingress allow: prometheus (prometheus ns) → exporter :5000. The amd-gpu ns
# runs the default-deny netpol-baseline (intra-ns only), so this explicit
# cross-ns ingress is what lets the `kubernetes-pods` scrape reach the pod.
# Mirror egress lives in services/prometheus.tf as `prometheus-to-gpu-metrics`.
resource "kubernetes_network_policy" "gpu_metrics_from_prometheus" {
  metadata {
    name      = "gpu-metrics-from-prometheus"
    namespace = kubernetes_namespace.amd_gpu.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { app = "amd-gpu-metrics-exporter" }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.prometheus.metadata[0].name
          }
        }
        pod_selector {
          match_labels = { app = "prometheus" }
        }
      }
      ports {
        protocol = "TCP"
        port     = "5000"
      }
    }
  }
}
