# In-cluster build pipelines for the thunderbolt frontend and backend images.
#
# Mirrors the mcp-searxng pattern: rootless BuildKit as a k8s Job in the
# `builder` namespace with a native-sidecar tailscale container for registry
# egress. Job name is suffixed with a sha256 of the build context so terraform
# only re-creates a Job (= triggers a rebuild) when any input file changes.
#
# Both Dockerfiles do `git clone` at build time, so the build context only
# needs the Dockerfile itself plus any overlay files the image COPYs
# (frontend: nginx.conf; backend: exa-override.ts). A separate git ref can be
# pinned via var.thunderbolt_ref — BuildKit receives it as a build-arg.
#
# Force a rebuild by touching any context file, bumping var.thunderbolt_ref,
# or tainting the kubernetes_manifest. Old completed Jobs accumulate; clean
# periodically with:
#   kubectl delete jobs -n builder --field-selector status.successful=1

locals {
  thunderbolt_frontend_context_files = {
    "Dockerfile" = file("${path.module}/../data/images/thunderbolt/frontend/Dockerfile")
    "nginx.conf" = file("${path.module}/../data/images/thunderbolt/frontend/nginx.conf")
  }

  thunderbolt_backend_context_files = {
    "Dockerfile"      = file("${path.module}/../data/images/thunderbolt/backend/Dockerfile")
    "exa-override.ts" = file("${path.module}/../data/images/thunderbolt/backend/exa-override.ts")
  }

  thunderbolt_frontend_context_hash = substr(sha256(join("\n",
    [for k, v in local.thunderbolt_frontend_context_files : "${k}:${v}"]
  )), 0, 8)

  thunderbolt_backend_context_hash = substr(sha256(join("\n",
    [for k, v in local.thunderbolt_backend_context_files : "${k}:${v}"]
  )), 0, 8)

  thunderbolt_frontend_build_job_name = "thunderbolt-frontend-build-${local.thunderbolt_frontend_context_hash}-${substr(sha256(var.thunderbolt_ref), 0, 6)}"
  thunderbolt_backend_build_job_name  = "thunderbolt-backend-build-${local.thunderbolt_backend_context_hash}-${substr(sha256(var.thunderbolt_ref), 0, 6)}"
}

resource "kubernetes_config_map" "thunderbolt_frontend_build_context" {
  metadata {
    name      = "thunderbolt-frontend-build-context"
    namespace = kubernetes_namespace.builder.metadata[0].name
  }
  data = local.thunderbolt_frontend_context_files
}

resource "kubernetes_manifest" "thunderbolt_frontend_build" {
  manifest = {
    apiVersion = "batch/v1"
    kind       = "Job"
    metadata = {
      name      = local.thunderbolt_frontend_build_job_name
      namespace = kubernetes_namespace.builder.metadata[0].name
    }
    spec = {
      backoffLimit = 2
      # No ttlSecondsAfterFinished: K8s would GC the Job and kubernetes_manifest
      # would re-create it on next apply, triggering a needless rebuild.
      template = {
        metadata = {
          labels = {
            app = "thunderbolt-frontend-build"
          }
          annotations = {
            "container.apparmor.security.beta.kubernetes.io/buildkit" = "unconfined"
          }
        }
        spec = {
          restartPolicy      = "Never"
          serviceAccountName = kubernetes_service_account.builder.metadata[0].name

          initContainers = [
            {
              name          = "tailscale"
              image         = var.image_tailscale
              restartPolicy = "Always"
              env = [
                { name = "TS_STATE_DIR", value = "/var/lib/tailscale" },
                { name = "TS_KUBE_SECRET", value = "thunderbolt-frontend-builder-tailscale-state" },
                { name = "TS_USERSPACE", value = "false" },
                {
                  name = "TS_AUTHKEY"
                  valueFrom = {
                    secretKeyRef = {
                      name = kubernetes_secret.builder_tailscale_auth.metadata[0].name
                      key  = "TS_AUTHKEY"
                    }
                  }
                },
                { name = "TS_HOSTNAME", value = "thunderbolt-frontend-builder" },
                { name = "TS_EXTRA_ARGS", value = "--login-server=https://${data.terraform_remote_state.homelab.outputs.headscale_server_fqdn}" },
              ]
              securityContext = {
                capabilities = {
                  add = ["NET_ADMIN"]
                }
              }
              volumeMounts = [
                { name = "dev-net-tun", mountPath = "/dev/net/tun" },
                { name = "tailscale-state", mountPath = "/var/lib/tailscale" },
              ]
            },
            {
              name    = "wait-for-tailscale"
              image   = var.image_busybox
              command = ["sh", "-c", "until nslookup ${local.thunderbolt_registry}; do echo 'waiting for tailscale dns'; sleep 2; done"]
            },
          ]

          containers = [
            {
              name    = "buildkit"
              image   = "moby/buildkit:rootless"
              command = ["buildctl-daemonless.sh"]
              args = [
                "build",
                "--frontend=dockerfile.v0",
                "--local=context=/workspace",
                "--local=dockerfile=/workspace",
                "--opt=build-arg:THUNDERBOLT_REF=${var.thunderbolt_ref}",
                "--output=type=image,name=${local.thunderbolt_frontend_image},push=true",
              ]
              env = [
                { name = "BUILDKITD_FLAGS", value = "--oci-worker-no-process-sandbox" },
              ]
              securityContext = {
                runAsUser  = 1000
                runAsGroup = 1000
                seccompProfile = {
                  type = "Unconfined"
                }
              }
              volumeMounts = [
                { name = "context", mountPath = "/workspace", readOnly = true },
                { name = "docker-config", mountPath = "/home/user/.docker", readOnly = true },
              ]
              resources = {
                requests = { cpu = "500m", memory = "1Gi" }
                limits   = { cpu = "4", memory = "6Gi" }
              }
            },
          ]

          volumes = [
            {
              name = "context"
              configMap = {
                name = kubernetes_config_map.thunderbolt_frontend_build_context.metadata[0].name
              }
            },
            {
              name = "docker-config"
              secret = {
                secretName = kubernetes_secret.builder_registry_pull_secret.metadata[0].name
                items = [
                  { key = ".dockerconfigjson", path = "config.json" },
                ]
              }
            },
            {
              name = "dev-net-tun"
              hostPath = {
                path = "/dev/net/tun"
                type = "CharDevice"
              }
            },
            {
              name     = "tailscale-state"
              emptyDir = {}
            },
          ]
        }
      }
    }
  }

  computed_fields = [
    "metadata.labels",
    "metadata.annotations",
    "spec.template.metadata.labels",
    "spec.selector",
  ]

  wait {
    condition {
      type   = "Complete"
      status = "True"
    }
  }

  timeouts {
    create = "20m"
    update = "20m"
  }

  depends_on = [
    kubernetes_namespace.builder,
    kubernetes_role_binding.builder_tailscale,
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_secret.builder_tailscale_auth,
    kubernetes_config_map.thunderbolt_frontend_build_context,
  ]
}

resource "kubernetes_config_map" "thunderbolt_backend_build_context" {
  metadata {
    name      = "thunderbolt-backend-build-context"
    namespace = kubernetes_namespace.builder.metadata[0].name
  }
  data = local.thunderbolt_backend_context_files
}

resource "kubernetes_manifest" "thunderbolt_backend_build" {
  manifest = {
    apiVersion = "batch/v1"
    kind       = "Job"
    metadata = {
      name      = local.thunderbolt_backend_build_job_name
      namespace = kubernetes_namespace.builder.metadata[0].name
    }
    spec = {
      backoffLimit = 2
      # No ttlSecondsAfterFinished: K8s would GC the Job and kubernetes_manifest
      # would re-create it on next apply, triggering a needless rebuild.
      template = {
        metadata = {
          labels = {
            app = "thunderbolt-backend-build"
          }
          annotations = {
            "container.apparmor.security.beta.kubernetes.io/buildkit" = "unconfined"
          }
        }
        spec = {
          restartPolicy      = "Never"
          serviceAccountName = kubernetes_service_account.builder.metadata[0].name

          initContainers = [
            {
              name          = "tailscale"
              image         = var.image_tailscale
              restartPolicy = "Always"
              env = [
                { name = "TS_STATE_DIR", value = "/var/lib/tailscale" },
                { name = "TS_KUBE_SECRET", value = "thunderbolt-backend-builder-tailscale-state" },
                { name = "TS_USERSPACE", value = "false" },
                {
                  name = "TS_AUTHKEY"
                  valueFrom = {
                    secretKeyRef = {
                      name = kubernetes_secret.builder_tailscale_auth.metadata[0].name
                      key  = "TS_AUTHKEY"
                    }
                  }
                },
                { name = "TS_HOSTNAME", value = "thunderbolt-backend-builder" },
                { name = "TS_EXTRA_ARGS", value = "--login-server=https://${data.terraform_remote_state.homelab.outputs.headscale_server_fqdn}" },
              ]
              securityContext = {
                capabilities = {
                  add = ["NET_ADMIN"]
                }
              }
              volumeMounts = [
                { name = "dev-net-tun", mountPath = "/dev/net/tun" },
                { name = "tailscale-state", mountPath = "/var/lib/tailscale" },
              ]
            },
            {
              name    = "wait-for-tailscale"
              image   = var.image_busybox
              command = ["sh", "-c", "until nslookup ${local.thunderbolt_registry}; do echo 'waiting for tailscale dns'; sleep 2; done"]
            },
          ]

          containers = [
            {
              name    = "buildkit"
              image   = "moby/buildkit:rootless"
              command = ["buildctl-daemonless.sh"]
              args = [
                "build",
                "--frontend=dockerfile.v0",
                "--local=context=/workspace",
                "--local=dockerfile=/workspace",
                "--opt=build-arg:THUNDERBOLT_REF=${var.thunderbolt_ref}",
                "--output=type=image,name=${local.thunderbolt_backend_image},push=true",
              ]
              env = [
                { name = "BUILDKITD_FLAGS", value = "--oci-worker-no-process-sandbox" },
              ]
              securityContext = {
                runAsUser  = 1000
                runAsGroup = 1000
                seccompProfile = {
                  type = "Unconfined"
                }
              }
              volumeMounts = [
                { name = "context", mountPath = "/workspace", readOnly = true },
                { name = "docker-config", mountPath = "/home/user/.docker", readOnly = true },
              ]
              resources = {
                requests = { cpu = "300m", memory = "768Mi" }
                limits   = { cpu = "3", memory = "3Gi" }
              }
            },
          ]

          volumes = [
            {
              name = "context"
              configMap = {
                name = kubernetes_config_map.thunderbolt_backend_build_context.metadata[0].name
              }
            },
            {
              name = "docker-config"
              secret = {
                secretName = kubernetes_secret.builder_registry_pull_secret.metadata[0].name
                items = [
                  { key = ".dockerconfigjson", path = "config.json" },
                ]
              }
            },
            {
              name = "dev-net-tun"
              hostPath = {
                path = "/dev/net/tun"
                type = "CharDevice"
              }
            },
            {
              name     = "tailscale-state"
              emptyDir = {}
            },
          ]
        }
      }
    }
  }

  computed_fields = [
    "metadata.labels",
    "metadata.annotations",
    "spec.template.metadata.labels",
    "spec.selector",
  ]

  wait {
    condition {
      type   = "Complete"
      status = "True"
    }
  }

  timeouts {
    create = "20m"
    update = "20m"
  }

  depends_on = [
    kubernetes_namespace.builder,
    kubernetes_role_binding.builder_tailscale,
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_secret.builder_tailscale_auth,
    kubernetes_config_map.thunderbolt_backend_build_context,
  ]
}
