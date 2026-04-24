resource "kubernetes_config_map" "mcp_memory_build_context" {
  metadata {
    name      = "mcp-memory-build-context"
    namespace = kubernetes_namespace.builder.metadata[0].name
  }

  data = {
    "Dockerfile" = file("${path.module}/../data/images/mcp-memory/Dockerfile")
    "server.py"  = file("${path.module}/../data/images/mcp-memory/server.py")
  }
}

locals {
  mcp_memory_dockerfile_hash = substr(sha256(
    "${file("${path.module}/../data/images/mcp-memory/Dockerfile")}${file("${path.module}/../data/images/mcp-memory/server.py")}"
  ), 0, 8)
  mcp_memory_build_job_name = "mcp-memory-build-${local.mcp_memory_dockerfile_hash}"
}

resource "kubernetes_manifest" "mcp_memory_build" {
  manifest = {
    apiVersion = "batch/v1"
    kind       = "Job"
    metadata = {
      name      = local.mcp_memory_build_job_name
      namespace = kubernetes_namespace.builder.metadata[0].name
    }
    spec = {
      backoffLimit = 2
      ttlSecondsAfterFinished = 3600
      template = {
        metadata = {
          labels = {
            app = "mcp-memory-build"
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
                { name = "TS_KUBE_SECRET", value = "mcp-memory-builder-tailscale-state" },
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
                { name = "TS_HOSTNAME", value = "mcp-memory-builder" },
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
                "--output=type=image,name=${local.thunderbolt_registry}/mcp-memory:latest,push=true",
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
                requests = { cpu = "200m", memory = "512Mi" }
                limits   = { cpu = "2", memory = "2Gi" }
              }
            },
          ]

          volumes = [
            {
              name = "context"
              configMap = {
                name = kubernetes_config_map.mcp_memory_build_context.metadata[0].name
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
    kubernetes_config_map.mcp_memory_build_context,
  ]
}
