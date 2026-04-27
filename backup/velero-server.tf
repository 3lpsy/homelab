# Velero server Deployment. One replica — Velero's controller is leader-elected
# but a single instance is the supported default and matches `velero install`.
#
# Init container copies the AWS provider plugin into the shared `plugins`
# emptyDir which the main container mounts at /plugins. Velero discovers
# plugins by scanning that directory at startup.
#
# Args mirror what `velero install --uploader-type=kopia
# --default-volumes-to-fs-backup` would produce. Avoid `--features=` if no
# experimental features are needed; setting it to empty is the safe default.

resource "kubernetes_deployment" "velero" {
  metadata {
    name      = "velero"
    namespace = kubernetes_namespace.velero.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "velero"
      component                = "velero"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        name = "velero"
      }
    }

    template {
      metadata {
        labels = {
          name                     = "velero"
          "app.kubernetes.io/name" = "velero"
          component                = "velero"
        }
        annotations = {
          # Force a rollout when the AWS creds Secret content changes. Reloader
          # would also catch this once it's installed cluster-wide, but having
          # the annotation here makes the dependency explicit.
          "checksum/cloud-credentials" = sha256(kubernetes_secret.velero_aws_creds.data["cloud"])
        }
      }

      spec {
        service_account_name = kubernetes_service_account.velero.metadata[0].name
        restart_policy       = "Always"

        init_container {
          name              = "velero-plugin-for-aws"
          image             = var.velero_aws_plugin_image
          image_pull_policy = "IfNotPresent"

          volume_mount {
            name       = "plugins"
            mount_path = "/target"
          }
        }

        container {
          name              = "velero"
          image             = var.velero_image
          image_pull_policy = "IfNotPresent"

          command = ["/velero"]
          args = [
            "server",
            "--uploader-type=kopia",
            "--default-volumes-to-fs-backup=true",
            "--log-level=info",
            "--log-format=text",
          ]

          port {
            name           = "metrics"
            container_port = 8085
          }

          volume_mount {
            name       = "plugins"
            mount_path = "/plugins"
          }

          volume_mount {
            name       = "scratch"
            mount_path = "/scratch"
          }

          volume_mount {
            name       = "cloud-credentials"
            mount_path = "/credentials"
            read_only  = true
          }

          env {
            name  = "VELERO_SCRATCH_DIR"
            value = "/scratch"
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
            name  = "LD_LIBRARY_PATH"
            value = "/plugins"
          }

          env {
            name  = "AWS_SHARED_CREDENTIALS_FILE"
            value = "/credentials/cloud"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }
        }

        volume {
          name = "plugins"
          empty_dir {}
        }

        volume {
          name = "scratch"
          empty_dir {}
        }

        volume {
          name = "cloud-credentials"
          secret {
            secret_name = kubernetes_secret.velero_aws_creds.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_cluster_role_binding.velero,
    kubernetes_role_binding.velero,
  ]
}
