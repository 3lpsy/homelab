terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

locals {
  # Standard env every server gets. Caller's extras append.
  base_env = [
    { name = "MCP_HOST", value = "0.0.0.0", value_from_secret = null },
    { name = "MCP_PORT", value = "8000", value_from_secret = null },
    { name = "LOG_LEVEL", value = var.log_level, value_from_secret = null },
    {
      name              = "MCP_API_KEYS"
      value             = null
      value_from_secret = { name = "mcp-auth", key = "api_keys_csv" }
    },
  ]

  full_env = concat(local.base_env, [
    for e in var.extra_env : {
      name              = e.name
      value             = try(e.value, null)
      value_from_secret = try(e.value_from_secret, null)
    }
  ])

  # Reload annotation: base + caller extras, comma-joined.
  reload_value = join(",", concat(["mcp-auth", "mcp-shared-tls"], var.extra_reload_secrets))

  base_annotations = {
    "build-job"                           = var.build_job_name
    "secret.reloader.stakater.com/reload" = local.reload_value
  }

  pod_annotations = merge(local.base_annotations, var.extra_pod_annotations)

  # Volumes carried by the main container's volume_mount block.
  # secrets-store is always present; data only when caller passes data_volume.
  data_volume_mounts = var.data_volume == null ? [] : [
    { name = "data", mount_path = var.data_volume.mount_path, read_only = false }
  ]
  extra_volume_mounts = [
    for v in var.extra_csi_volumes : { name = v.name, mount_path = v.mount_path, read_only = true }
  ]
}

resource "kubernetes_deployment" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = var.name
      }
    }

    template {
      metadata {
        labels = {
          app = var.name
        }
        annotations = local.pod_annotations
      }

      spec {
        service_account_name = var.service_account_name

        image_pull_secrets {
          name = var.image_pull_secret_name
        }

        security_context {
          run_as_non_root = true
          # fs_group + fs_group_change_policy come from var.pod_fs_group +
          # var.data_volume; both blocks are conditional below.
          fs_group               = var.pod_fs_group
          fs_group_change_policy = var.data_volume == null ? null : "OnRootMismatch"
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        dynamic "host_aliases" {
          for_each = var.host_aliases
          content {
            ip        = host_aliases.value.ip
            hostnames = host_aliases.value.hostnames
          }
        }

        # Always-on wait-for-secrets init: gates the main container until
        # the shared mcp-auth CSI mount lands.
        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "mcp_shared_api_keys_csv"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
          security_context {
            run_as_user  = 1000
            run_as_group = 1000
          }
        }

        # Per-caller extra waits (e.g. mcp-litellm's second SPC).
        dynamic "init_container" {
          for_each = var.extra_secret_waits
          content {
            name  = "wait-for-${replace(init_container.value.secret_file, "_", "-")}"
            image = var.image_busybox
            command = [
              "sh", "-c",
              templatefile("${path.module}/../../data/scripts/wait-for-secrets.sh.tpl", {
                secret_file = init_container.value.secret_file
              })
            ]
            volume_mount {
              name       = init_container.value.csi_volume_name
              mount_path = "/mnt/secrets"
              read_only  = true
            }
            security_context {
              run_as_user  = 1000
              run_as_group = 1000
            }
          }
        }

        container {
          name              = var.name
          image             = var.image
          image_pull_policy = var.image_pull_policy

          dynamic "env" {
            for_each = local.full_env
            content {
              name  = env.value.name
              value = env.value.value
              dynamic "value_from" {
                for_each = env.value.value_from_secret == null ? [] : [env.value.value_from_secret]
                content {
                  secret_key_ref {
                    name = value_from.value.name
                    key  = value_from.value.key
                  }
                }
              }
            }
          }

          port {
            container_port = 8000
            name           = "http"
          }

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          # ~90s grace before restart so a slow tool call or upstream blip
          # doesn't flap the pod.
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8000
            }
            initial_delay_seconds = 20
            period_seconds        = 30
            failure_threshold     = 3
            timeout_seconds       = 5
          }

          security_context {
            run_as_user                = 1000
            run_as_group               = 1000
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
            seccomp_profile {
              type = "RuntimeDefault"
            }
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
          # /tmp emptyDir for Python / certifi temp files; required because
          # read_only_root_filesystem is on.
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          dynamic "volume_mount" {
            for_each = local.data_volume_mounts
            content {
              name       = volume_mount.value.name
              mount_path = volume_mount.value.mount_path
              read_only  = volume_mount.value.read_only
            }
          }

          dynamic "volume_mount" {
            for_each = local.extra_volume_mounts
            content {
              name       = volume_mount.value.name
              mount_path = volume_mount.value.mount_path
              read_only  = volume_mount.value.read_only
            }
          }
        }

        # Always-on volumes.
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = var.shared_secret_provider_class
            }
          }
        }
        volume {
          name = "tmp"
          empty_dir {}
        }

        dynamic "volume" {
          for_each = var.data_volume == null ? [] : [var.data_volume]
          content {
            name = "data"
            persistent_volume_claim {
              claim_name = volume.value.pvc_name
            }
          }
        }

        dynamic "volume" {
          for_each = var.extra_csi_volumes
          content {
            name = volume.value.name
            csi {
              driver    = "secrets-store.csi.k8s.io"
              read_only = true
              volume_attributes = {
                secretProviderClass = volume.value.secret_provider_class_name
              }
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
  }
  spec {
    selector = {
      app = var.name
    }
    port {
      name        = "http"
      port        = 8000
      target_port = 8000
    }
  }
}
