terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

locals {
  # ConfigMap data keys must match `[-._a-zA-Z0-9]+` per Kubernetes API
  # validation, so any `context_dirs` key containing `/` is encoded to a flat
  # `dir-<md5>` key in the ConfigMap. The original subpath is restored at
  # mount time via the volume's `items[].path` field (which IS allowed to
  # contain `/`). Keep the encoding deterministic so the build_context
  # ConfigMap and the volume's items list agree on every plan.
  context_dir_keys = {
    for path, _ in var.context_dirs : path => "dir-${md5(path)}"
  }
}

resource "kubernetes_config_map" "build_context" {
  metadata {
    name      = "${var.name}-build-context"
    namespace = var.shared.builder_namespace
  }

  data = merge(
    var.context_files,
    { for path, content in var.context_dirs : local.context_dir_keys[path] => content },
  )
}

locals {
  # `items` controls which ConfigMap data keys appear under the volume mount
  # AND where each one lands. Setting it means we must include EVERY key —
  # both flat context_files (key == path) and the sanitized context_dirs
  # entries (sanitized key, original subpath as path).
  context_volume_items = concat(
    [for k, _ in var.context_files : { key = k, path = k }],
    [for path, _ in var.context_dirs : { key = local.context_dir_keys[path], path = path }],
  )

  # Cache tag for BuildKit's `--export-cache` / `--import-cache`. Lives
  # alongside the runtime image in the same registry, distinguished only
  # by tag. e.g. registry/foo:latest -> registry/foo:cache. Caller can
  # override via `var.cache_ref` if the cache should live elsewhere.
  effective_cache_ref = (
    var.cache_ref != "" ? var.cache_ref :
    "${join(":", slice(split(":", var.image_ref), 0, length(split(":", var.image_ref)) - 1))}:cache"
  )

  build_arg_flags = [
    for k, v in var.build_args : "--opt=build-arg:${k}=${v}"
  ]

  buildctl_args = concat(
    [
      "build",
      "--frontend=dockerfile.v0",
      "--local=context=/workspace",
      "--local=dockerfile=/workspace",
      # plain progress: line-buffered, no carriage-return overwrites. Default
      # `auto` tries to detect a TTY in a Job context and sometimes makes
      # `kubectl logs` look frozen mid-step (the "248 byte blob stuck" log
      # we saw was actually carriage-return progress, not a hang).
      "--progress=plain",
    ],
    local.build_arg_flags,
    [
      "--output=type=image,name=${var.image_ref},push=true",
      # Persistent layer cache.
      # - mode=max: captures intermediate stages (handy for multi-stage
      #   Dockerfiles like thunderbolt-frontend's builder + runtime).
      # - compression=zstd,force-compression=true: smaller + faster than
      #   gzip default; speeds push/pull and reduces registry PVC growth.
      # - oci-mediatypes=true,image-manifest=true: modern OCI image-manifest
      #   layout for cache (single manifest instead of OCI index). Better
      #   cross-tool compat and slightly more efficient on import.
      # On first run the import target doesn't exist yet — BuildKit logs a
      # non-fatal warning and proceeds without cache, then exports for next
      # time. After that, retries / small Dockerfile tweaks reuse layers.
      "--export-cache=type=registry,ref=${local.effective_cache_ref},mode=max,compression=zstd,force-compression=true,oci-mediatypes=true,image-manifest=true",
      # ignore-error=true: when the :cache tag doesn't exist yet (first run
      # for an image, or cache pruned manually), BuildKit can hang on the
      # cache manifest HEAD probe instead of cleanly recovering. Setting
      # ignore-error makes the import failure non-fatal so the build proceeds
      # and the export-cache step on success populates :cache for next time.
      "--import-cache=type=registry,ref=${local.effective_cache_ref},ignore-error=true",
    ],
  )

  # Sentinel for pod-template fields not captured by other hash inputs.
  # Bump the sentinel string whenever the pod template changes in ways
  # `buildctl_args` and `context_files` don't capture. Job spec.template
  # is immutable, so this forces a clean destroy-and-recreate via the
  # `job_name` hash.
  pod_spec_sentinel = "host-aliases=v1,bk=v0.29.0,debug=off,tmpdir,pprof,context-items=v1,materialize-context=v1"

  # Hash mixes every input that affects the Job spec — context files,
  # build-args, image_ref, the full buildctl args list, and the
  # pod-spec sentinel. Any change produces a new Job name.
  context_hash = substr(sha256(join("\n",
    concat(
      [for k, v in var.context_files : "${k}:${v}"],
      # Prefix dir entries so a `context_files` key that happens to equal
      # a `context_dirs` path can't silently collide on the hash input.
      [for k, v in var.context_dirs : "dir:${k}:${v}"],
      [var.context_hash_extra],
      local.buildctl_args,
      [local.pod_spec_sentinel],
    )
  )), 0, 8)

  job_name = "${var.name}-build-${local.context_hash}"
}

resource "kubernetes_manifest" "build" {
  manifest = {
    apiVersion = "batch/v1"
    kind       = "Job"
    metadata = {
      name      = local.job_name
      namespace = var.shared.builder_namespace
    }
    spec = {
      backoffLimit = 2
      # No ttlSecondsAfterFinished: K8s would GC the Job and kubernetes_manifest
      # would re-create it on next apply, triggering a needless rebuild.
      template = {
        metadata = {
          labels = {
            app = "${var.name}-build"
          }
          annotations = {
            "container.apparmor.security.beta.kubernetes.io/buildkit" = "unconfined"
          }
        }
        spec = {
          restartPolicy      = "Never"
          serviceAccountName = var.shared.builder_service_account

          # Pin every registry FQDN to its in-cluster Service ClusterIP so
          # the buildkitd.toml mirror entries (which still use the FQDN
          # form because BuildKit's resolver validates against cert SANs)
          # land on the nginx :443 of the corresponding registry pod.
          hostAliases = [
            { ip = var.shared.registry_cluster_ip, hostnames = [var.shared.registry_fqdn] },
            { ip = var.shared.registry_dockerio_cluster_ip, hostnames = [var.shared.registry_dockerio_fqdn] },
            { ip = var.shared.registry_ghcrio_cluster_ip, hostnames = [var.shared.registry_ghcrio_fqdn] },
          ]

          # Materialize the ConfigMap into an emptyDir before buildkit
          # reads it. Direct ConfigMap mounts use a symlink chain
          # (`<file>` -> `..data/<file>`) that BuildKit's fsutil context
          # streamer can't follow: fsutil skips dotfile-prefixed paths,
          # so the `..data` symlink target appears missing during COPY.
          # Result was every `COPY <file>` failing with "/<file>: not
          # found" while the Dockerfile itself loaded fine (it goes
          # through a different code path that resolves via the OS).
          # `cp -rL` follows the symlinks and writes plain files into
          # the emptyDir; buildkit then sees a normal directory.
          initContainers = [
            {
              name    = "stage-context"
              image   = var.shared.image_busybox
              command = [
                "sh", "-c",
                "cp -rL /context-src/. /workspace/ && chown -R 1000:1000 /workspace",
              ]
              volumeMounts = [
                { name = "context-src", mountPath = "/context-src", readOnly = true },
                { name = "context", mountPath = "/workspace" },
              ]
            },
          ]

          containers = [
            {
              name    = "buildkit"
              image   = var.shared.image_buildkit
              command = ["buildctl-daemonless.sh"]
              args    = local.buildctl_args
              env = [
                {
                  name  = "BUILDKITD_FLAGS"
                  value = "--oci-worker-no-process-sandbox${var.shared.buildkit_debug ? " --debug" : ""}"
                },
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
                {
                  name      = "buildkitd-config"
                  mountPath = "/home/user/.config/buildkit/buildkitd.toml"
                  subPath   = "buildkitd.toml"
                  readOnly  = true
                },
                # /tmp emptyDir: buildctl-daemonless.sh writes its socket and
                # scratch files under /tmp. Today the container's overlay
                # tmp works, but mounting an emptyDir makes the pod
                # readOnlyRootFilesystem-ready for future hardening.
                { name = "buildkit-tmp", mountPath = "/tmp" },
              ]
              resources = var.resources
            },
          ]

          volumes = [
            {
              name     = "context"
              emptyDir = {}
            },
            {
              name = "context-src"
              configMap = {
                name  = kubernetes_config_map.build_context.metadata[0].name
                # `items` lists every key the volume should expose AND the
                # path it should land at — required to materialize
                # `context_dirs` entries under their original subpath.
                items = local.context_volume_items
              }
            },
            {
              name = "docker-config"
              secret = {
                secretName = var.shared.builder_registry_pull_secret
                items = [
                  { key = ".dockerconfigjson", path = "config.json" },
                ]
              }
            },
            {
              name = "buildkitd-config"
              configMap = {
                name = var.shared.builder_buildkitd_config_configmap
              }
            },
            {
              name     = "buildkit-tmp"
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
    create = var.timeout
    update = var.timeout
  }

  depends_on = [
    kubernetes_config_map.build_context,
  ]
}
