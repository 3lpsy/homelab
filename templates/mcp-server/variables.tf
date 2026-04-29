variable "name" {
  description = "Server identifier — drives Deployment, Service, and label values. e.g. \"mcp-filesystem\"."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace the Deployment + Service land in. The shared `mcp` namespace for every current caller."
  type        = string
}

variable "image" {
  description = "Container image reference for the main MCP container (FQDN + tag)."
  type        = string
}

variable "build_job_name" {
  description = "Build Job name from the buildkit-job module. Used as the `build-job` annotation so the pod rolls when the image rebuilds."
  type        = string
}

variable "service_account_name" {
  description = "ServiceAccount the pod runs under. Most callers use the shared `mcp` SA; mcp-k8s uses a dedicated one for K8s API RBAC."
  type        = string
}

variable "image_pull_secret_name" {
  description = "Pull secret for the in-cluster registry."
  type        = string
}

variable "shared_secret_provider_class" {
  description = "Name of the SecretProviderClass that exposes the shared `mcp-auth` + `mcp-shared-tls` secrets via CSI."
  type        = string
}

variable "log_level" {
  description = "LOG_LEVEL env passed into the server."
  type        = string
}

variable "extra_env" {
  description = "Per-server env vars appended after the four standard ones (MCP_HOST, MCP_PORT, LOG_LEVEL, MCP_API_KEYS)."
  type = list(object({
    name              = string
    value             = optional(string)
    value_from_secret = optional(object({
      name = string
      key  = string
    }))
  }))
  default = []
}

variable "resources" {
  description = "Container resource requests/limits."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "50m", memory = "128Mi" }
    limits   = { cpu = "500m", memory = "512Mi" }
  }
}

variable "pod_fs_group" {
  description = "Pod-level fs_group. Set when the CSI secrets-store mount needs group read (mcp-k8s) or a data PVC needs group write (filesystem, memory). Null disables."
  type        = number
  default     = null
}

variable "data_volume" {
  description = "Optional data PVC mounted into the main container. mcp-filesystem and mcp-memory share one. When set, fs_group_change_policy is forced to OnRootMismatch."
  type = object({
    pvc_name   = string
    mount_path = string
  })
  default = null
}

variable "extra_secret_waits" {
  description = "Extra wait-for-secrets init containers. Each entry waits for `secret_file` to materialise on a CSI volume named `csi_volume_name` (which must appear in extra_csi_volumes)."
  type = list(object({
    secret_file     = string
    csi_volume_name = string
  }))
  default = []
}

variable "extra_csi_volumes" {
  description = "Extra CSI secrets-store volumes mounted into the main container. The `secrets-store` volume backed by shared_secret_provider_class is always mounted; this list is for additional providers (e.g. mcp-litellm's own SPC)."
  type = list(object({
    name                       = string
    secret_provider_class_name = string
    mount_path                 = string
  }))
  default = []
}

variable "host_aliases" {
  description = "Pod hostAliases entries. Used by callers that resolve a tailnet FQDN to an in-cluster Service ClusterIP (mcp-litellm, mcp-searxng)."
  type = list(object({
    ip        = string
    hostnames = list(string)
  }))
  default = []
}

variable "extra_reload_secrets" {
  description = "Extra entries appended to the `secret.reloader.stakater.com/reload` annotation. The base `mcp-auth,mcp-shared-tls` always applies."
  type        = list(string)
  default     = []
}

variable "extra_pod_annotations" {
  description = "Extra annotations merged into the pod template metadata."
  type        = map(string)
  default     = {}
}

variable "image_pull_policy" {
  description = "Container image_pull_policy. Defaults to Always so `:latest` rebuilds get picked up on rollout."
  type        = string
  default     = "Always"
}

variable "image_busybox" {
  description = "Busybox image used by the wait-for-secrets init containers."
  type        = string
}
