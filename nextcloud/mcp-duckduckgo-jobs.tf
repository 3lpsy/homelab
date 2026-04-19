# In-cluster build pipeline for the mcp-duckduckgo image.
#
# Runs BuildKit (rootless, daemonless) as a k8s Job in the shared `builder`
# namespace. A tailscale native sidecar (initContainer + restartPolicy: Always)
# joins the pod netns as `builder_user` so the rootless buildkit can reach the
# internal registry over the tailnet. Job name is suffixed with sha256 of the
# Dockerfile — terraform only creates a new Job (= rebuild) when the Dockerfile
# content changes. Force a rebuild by tainting the resource or touching the
# Dockerfile.
#
# The Job is defined via `kubernetes_manifest` (raw YAML) because native-sidecar
# `initContainers[].restartPolicy` requires a newer kubernetes provider than is
# pinned here. Old completed Jobs accumulate — clean periodically:
#   kubectl delete jobs -n builder --field-selector status.successful=1

resource "kubernetes_config_map" "mcp_duckduckgo_build_context" {
  metadata {
    name      = "mcp-duckduckgo-build-context"
    namespace = kubernetes_namespace.builder.metadata[0].name
  }

  data = {
    "Dockerfile" = file("${path.module}/../data/images/mcp-duckduckgo/Dockerfile")
  }
}

locals {
  mcp_duckduckgo_dockerfile_hash = substr(sha256(file("${path.module}/../data/images/mcp-duckduckgo/Dockerfile")), 0, 8)
  mcp_duckduckgo_build_job_name  = "mcp-duckduckgo-build-${local.mcp_duckduckgo_dockerfile_hash}"
}

resource "kubernetes_manifest" "mcp_duckduckgo_build" {
  manifest = {
    apiVersion = "batch/v1"
    kind       = "Job"
    metadata = {
      name      = local.mcp_duckduckgo_build_job_name
      namespace = kubernetes_namespace.builder.metadata[0].name
    }
    spec = {
      backoffLimit = 2
      template = {
        metadata = {
          labels = {
            app = "mcp-duckduckgo-build"
          }
          annotations = {
            # AppArmor unconfined — required for rootless buildkit on k8s < 1.30.
            # On k8s >= 1.30 the pod-spec field takes precedence.
            "container.apparmor.security.beta.kubernetes.io/buildkit" = "unconfined"
          }
        }
        spec = {
          restartPolicy      = "Never"
          serviceAccountName = kubernetes_service_account.builder.metadata[0].name

          initContainers = [
            {
              # Native sidecar: restartPolicy=Always on an init container means
              # it starts during init phase, stays running while main containers
              # run, and terminates automatically when they finish.
              name          = "tailscale"
              image         = var.image_tailscale
              restartPolicy = "Always"
              env = [
                { name = "TS_STATE_DIR", value = "/var/lib/tailscale" },
                { name = "TS_KUBE_SECRET", value = "mcp-duckduckgo-builder-tailscale-state" },
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
                { name = "TS_HOSTNAME", value = "mcp-duckduckgo-builder" },
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
                "--output=type=image,name=${local.thunderbolt_registry}/mcp-duckduckgo:latest,push=true",
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
                { name = "dockerfile", mountPath = "/workspace", readOnly = true },
                { name = "docker-config", mountPath = "/home/user/.docker", readOnly = true },
              ]
              resources = {
                requests = { cpu = "200m", memory = "512Mi" }
                limits   = { cpu = "2", memory = "2Gi" }
              }
            },
          ]

          volumes = [
            {
              name = "dockerfile"
              configMap = {
                name = kubernetes_config_map.mcp_duckduckgo_build_context.metadata[0].name
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
    create = "10m"
    update = "10m"
  }

  depends_on = [
    kubernetes_namespace.builder,
    kubernetes_role_binding.builder_tailscale,
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_secret.builder_tailscale_auth,
    kubernetes_config_map.mcp_duckduckgo_build_context,
  ]
}
