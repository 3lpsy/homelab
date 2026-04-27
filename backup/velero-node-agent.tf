# Node-agent DaemonSet — required for File System Backup (FSB). Runs on every
# node, mounts the kubelet's pod root via hostPath so it can read PVC contents
# through the pod's filesystem and ship them via the kopia uploader.
#
# Privileged + runAsUser=0 because reading other pods' volumes requires it.
# Tolerates every taint so single-node K3s with control-plane taints still
# schedules the agent.

resource "kubernetes_daemonset" "node_agent" {
  metadata {
    name      = "node-agent"
    namespace = kubernetes_namespace.velero.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "velero"
      component                = "node-agent"
    }
  }

  spec {
    selector {
      match_labels = {
        name = "node-agent"
      }
    }

    template {
      metadata {
        labels = {
          name                     = "node-agent"
          "app.kubernetes.io/name" = "velero"
          component                = "node-agent"
        }
        annotations = {
          "checksum/cloud-credentials" = sha256(kubernetes_secret.velero_aws_creds.data["cloud"])
        }
      }

      spec {
        service_account_name = kubernetes_service_account.velero.metadata[0].name

        # Run on every node, including those with NoSchedule taints (control plane).
        toleration {
          operator = "Exists"
        }

        security_context {
          run_as_user = 0
        }

        container {
          name              = "node-agent"
          image             = var.velero_image
          image_pull_policy = "IfNotPresent"

          command = ["/velero"]
          args = [
            "node-agent",
            "server",
          ]

          port {
            name           = "http-monitoring"
            container_port = 8085
          }

          volume_mount {
            name       = "cloud-credentials"
            mount_path = "/credentials"
            read_only  = true
          }

          # mount_propagation = "HostToContainer" so newly-created pod volumes
          # appear inside the container without restarting node-agent.
          volume_mount {
            name              = "host-pods"
            mount_path        = "/host_pods"
            mount_propagation = "HostToContainer"
          }

          volume_mount {
            name       = "scratch"
            mount_path = "/scratch"
          }

          env {
            name = "VELERO_NAMESPACE"
            value_from {
              field_ref {
                field_path = "metadata.namespace"
              }
            }
          }

          env {
            name  = "VELERO_SCRATCH_DIR"
            value = "/scratch"
          }

          env {
            name = "NODE_NAME"
            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }

          env {
            name  = "AWS_SHARED_CREDENTIALS_FILE"
            value = "/credentials/cloud"
          }

          security_context {
            privileged  = true
            run_as_user = 0
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }
        }

        volume {
          name = "cloud-credentials"
          secret {
            secret_name = kubernetes_secret.velero_aws_creds.metadata[0].name
          }
        }

        # K3s default kubelet root. If you ever change `--kubelet-root-dir` on
        # the node, update this hostPath in lockstep.
        volume {
          name = "host-pods"
          host_path {
            path = "/var/lib/kubelet/pods"
          }
        }

        volume {
          name = "scratch"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [
    kubernetes_cluster_role_binding.velero,
  ]
}
