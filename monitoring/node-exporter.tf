resource "kubernetes_daemonset" "node_exporter" {
  metadata {
    name      = "node-exporter"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { app = "node-exporter" }
  }

  spec {
    selector {
      match_labels = { app = "node-exporter" }
    }

    template {
      metadata {
        labels = { app = "node-exporter" }
      }

      spec {
        host_network                     = true
        host_pid                         = true
        automount_service_account_token  = false

        container {
          name  = "node-exporter"
          image = "prom/node-exporter:latest"

          args = [
            "--path.procfs=/host/proc",
            "--path.sysfs=/host/sys",
            "--path.rootfs=/host/root",
            "--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|var/lib/docker/.+|var/lib/kubelet/.+)($|/)",
          ]

          port {
            container_port = 9100
            host_port      = 9100
            name           = "metrics"
          }

          volume_mount {
            name              = "proc"
            mount_path        = "/host/proc"
            read_only         = true
          }
          volume_mount {
            name              = "sys"
            mount_path        = "/host/sys"
            read_only         = true
          }
          volume_mount {
            name              = "root"
            mount_path        = "/host/root"
            mount_propagation = "HostToContainer"
            read_only         = true
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "250m", memory = "128Mi" }
          }
        }

        volume {
          name = "proc"
          host_path { path = "/proc" }
        }
        volume {
          name = "sys"
          host_path { path = "/sys" }
        }
        volume {
          name = "root"
          host_path { path = "/" }
        }

        toleration {
          operator = "Exists"
        }
      }
    }
  }
}
