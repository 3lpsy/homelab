variable "name" {
  description = "Service identifier — drives the build Job's name and ConfigMap name. Must be unique per concurrent build."
  type        = string
}

variable "image_ref" {
  description = "Fully-qualified output image, e.g. `registry.hs.example.net/mcp-foo:latest`. BuildKit pushes here on success."
  type        = string
}

variable "context_files" {
  description = "Map of filename -> file content for the build context. Keys must include `Dockerfile`. Keys are flat (no `/`) — they land directly under /workspace in the BuildKit container. For files that need to live in a subdirectory of the context, use `context_dirs` instead."
  type        = map(string)
}

variable "context_dirs" {
  description = "Map of `subpath/file` -> file content for build-context files that need to live inside a subdirectory. ConfigMap data keys cannot contain `/`, so this module sanitizes each subpath to a flat key in the ConfigMap and uses `items[].path` on the volume mount to materialize them at the original subpath under /workspace. Keys may contain `/`; they're also mixed into context_hash so a content/path change rebuilds."
  type        = map(string)
  default     = {}
}

variable "build_args" {
  description = "Optional Dockerfile build-args. Each entry becomes `--opt=build-arg:<key>=<value>` on the BuildKit invocation."
  type        = map(string)
  default     = {}
}

variable "cache_ref" {
  description = "Optional override for the BuildKit registry-cache tag. Defaults to deriving from `image_ref` by replacing the last `:tag` with `:cache`. Override only if you want the cache to live in a different registry/repo than the runtime image."
  type        = string
  default     = ""
}

variable "context_hash_extra" {
  description = "Optional extra string mixed into the context hash. Use for inputs that aren't files but should still trigger a rebuild (e.g. a git ref)."
  type        = string
  default     = ""
}

variable "resources" {
  description = "Container resource requests/limits for the BuildKit container."
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  default = {
    requests = { cpu = "200m", memory = "512Mi" }
    limits   = { cpu = "2", memory = "2Gi" }
  }
}

variable "timeout" {
  description = "Terraform wait timeout for the Job to reach Complete=True. Bigger images / git clones may need 20m+."
  type        = string
  default     = "20m"
}

variable "shared" {
  description = "Shared `builder` namespace infrastructure threaded from the caller. Build a single local in the calling deployment and pass it to every buildkit-job module so call-sites are concise."
  type = object({
    builder_namespace                  = string
    builder_service_account            = string
    builder_registry_pull_secret       = string
    builder_buildkitd_config_configmap = string
    # Registry FQDNs + matching ClusterIPs threaded through to host_aliases
    # on each build Job pod. `registry` is the push target (where built
    # images land); `registry_dockerio` and `registry_ghcrio` are the
    # pull-through caches the buildkitd.toml mirrors point to.
    registry_fqdn                = string
    registry_cluster_ip          = string
    registry_dockerio_fqdn       = string
    registry_dockerio_cluster_ip = string
    registry_ghcrio_fqdn         = string
    registry_ghcrio_cluster_ip   = string
    image_buildkit               = string
    # Used by the stage-context init container that materializes the
    # build-context ConfigMap into a real (non-symlink) directory.
    image_busybox = string
    # Enables `--debug` on buildkitd. Adds verbose internal logs (resolver
    # state, fetcher goroutines) — useful when diagnosing wedges. Off by
    # default; flip to true on the calling deployment when something stalls.
    buildkit_debug = bool
  })
}
