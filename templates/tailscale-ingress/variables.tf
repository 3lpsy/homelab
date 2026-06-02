variable "name" {
  description = "Logical service name; used to derive Secret/Role/RoleBinding names (<name>-tailscale-state, <name>-tailscale-auth, <name>-tailscale)."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace where the tailscale state Secret + RBAC live. Must already exist."
  type        = string
}

variable "service_account_name" {
  description = "ServiceAccount the RoleBinding authorizes. Caller owns this SA so the same one can be reused across services in a shared namespace."
  type        = string
}

variable "tailnet_user_id" {
  description = "Headscale user ID for the pre-auth key (e.g. data.terraform_remote_state.homelab.outputs.tailnet_user_map.<svc>_server_user)."
  type        = string
}

variable "reusable" {
  description = "Whether the headscale pre-auth key can be reused across pod restarts."
  type        = bool
  default     = true
}

variable "time_to_expire" {
  description = "Headscale pre-auth key TTL. Three years matches the existing per-service shape."
  type        = string
  default     = "3y"
}

variable "manage_role" {
  description = "Create the Role + RoleBinding granting tailscaled get/update/patch on its state Secret. Set to false when multiple sidecars in the same namespace share an externally-managed Role that lists every state secret (e.g. registry-dockerio + registry-ghcrio under registry-proxy)."
  type        = bool
  default     = true
}

variable "role_name" {
  description = "Override for the Role + RoleBinding K8s name. Default: <name>-tailscale. Set when adopting the module against an existing service whose Role uses a different bare name (e.g. legacy `tailscale`) to avoid a destroy/create that would briefly drop RBAC during apply."
  type        = string
  default     = null
}

variable "state_secret_name" {
  description = "Override for the tailscale state Secret K8s name. Default: <name>-tailscale-state. Set when adopting the module against an existing service whose state Secret uses a different bare name to avoid a destroy/recreate that would force tailscaled to re-register via TS_AUTHKEY (brief outage)."
  type        = string
  default     = null
}

variable "auth_secret_name" {
  description = "Override for the tailscale TS_AUTHKEY Secret K8s name. Default: <name>-tailscale-auth. Same migration-preservation rationale as state_secret_name."
  type        = string
  default     = null
}
