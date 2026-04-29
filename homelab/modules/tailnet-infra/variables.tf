

variable "headscale_server_domain" {
  type = string
}
variable "headscale_key_path" {
  type = string
}
variable "api_key" {
  type      = string
  sensitive = true
}
variable "tailnet_users" {
  description = "Map of role keys to headscale usernames"
  type        = map(string)
}

variable "k8s_pod_cidr" {
  description = "K3s pod CIDR. Auto-approved as a subnet route advertised by group:node-server (delphi). Must match the value passed in cluster/cluster.tf so the route delphi advertises matches the auto-approver. End-to-end pod-IP reachability requires NetworkPolicy permitting tailnet ingress to the destination namespace."
  type        = string
  default     = "10.42.0.0/16"
}
