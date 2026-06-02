# AMD GPU device plugin (Phase 3 of docs/CLUSTER.md).
#
# The ROCm k8s-device-plugin DaemonSet enumerates the discrete AMD GPUs from
# sysfs and advertises them to the kubelet as the `amd.com/gpu` extended
# resource, so pods can request `resources.limits."amd.com/gpu" = "N"` and have
# /dev/kfd + /dev/dri/renderD* injected automatically.
#
# Split of concerns: the ROCm *host driver* (userspace + the in-tree amdgpu
# kernel module) is provisioned on the node by cluster/ (node-provision-server
# `rocm_install`, gated on enable_rocm). THIS is the Kubernetes side — a plain
# DaemonSet, so it lives in services/ like every other workload.
#
# Pinned to artemis: delphi has no discrete AMD GPU, and the plugin only needs
# to run where the GPUs + driver are. nodeSelector keeps it off delphi; the
# gpu=true:NoSchedule toleration lets it onto the tainted GPU node.
#
# No network: the plugin registers with the local kubelet over a hostPath unix
# socket and talks to nothing else (no apiserver) — so the namespace gets only
# the default-deny baseline, both egress allows off (matches node-exporter).
#
# Not included: the node-labeller (adds amd.com/gpu.product-name etc.). We
# target artemis with the `node=artemis` label already, so the extra labels +
# their apiserver RBAC aren't needed. Add later if a workload wants to schedule
# by GPU model rather than node.

resource "kubernetes_namespace" "amd_gpu" {
  metadata {
    name = "amd-gpu"
  }
}

resource "kubernetes_daemonset" "amd_gpu_device_plugin" {
  metadata {
    name      = "amd-gpu-device-plugin"
    namespace = kubernetes_namespace.amd_gpu.metadata[0].name
    labels    = { app = "amd-gpu-device-plugin" }
  }

  spec {
    selector {
      match_labels = { app = "amd-gpu-device-plugin" }
    }

    template {
      metadata {
        labels = { app = "amd-gpu-device-plugin" }
      }

      spec {
        automount_service_account_token = false

        # Only artemis has the GPUs + ROCm driver. The taint repels everything
        # without a gpu toleration; the nodeSelector keeps the plugin off delphi.
        node_selector = { node = "artemis" }

        toleration {
          key      = "gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        container {
          name              = "amd-gpu-device-plugin"
          image             = var.image_amd_gpu_device_plugin
          image_pull_policy = "Always"

          # Upstream default posture: no privilege escalation, all caps dropped.
          # The plugin only reads sysfs to count GPUs; device access happens in
          # the consuming pods, not here.
          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }

          # Register the device-plugin socket with the kubelet.
          volume_mount {
            name       = "device-plugin"
            mount_path = "/var/lib/kubelet/device-plugins"
          }
          # Enumerate GPUs via /sys/class/kfd + /sys/class/drm.
          volume_mount {
            name       = "sys"
            mount_path = "/sys"
            read_only  = true
          }

          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "100m", memory = "128Mi" }
          }
        }

        volume {
          name = "device-plugin"
          host_path { path = "/var/lib/kubelet/device-plugins" }
        }
        volume {
          name = "sys"
          host_path { path = "/sys" }
        }
      }
    }
  }
}

# Plugin talks only to the local kubelet (hostPath socket) — no cluster network.
module "amd_gpu_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace             = kubernetes_namespace.amd_gpu.metadata[0].name
  pod_cidr              = var.k8s_pod_cidr
  service_cidr          = var.k8s_service_cidr
  allow_internet_egress = false
  allow_kube_api_egress = false
}
