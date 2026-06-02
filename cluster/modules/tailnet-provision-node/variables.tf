

variable "server_ip" {
  type = string
}
variable "ssh_user" {
  type = string
}
variable "ssh_priv_key" {
  type = string
}
variable "nomad_hostname" {
  type = string
}
variable "tailnet_auth_key" {
  type = string
}

variable "headscale_server_domain" {
  type = string
}

variable "advertise_routes" {
  description = "Comma-separated CIDRs delphi advertises as a Tailscale subnet router. Set to the K8s pod CIDR so external tailnet clients (e.g. laptop) can reach pod IPs via delphi's flannel gateway. Empty disables advertising. Auto-approval is gated by `autoApprovers.routes` in the Headscale ACL policy (homelab/modules/tailnet-infra/main.tf). Requires NetworkPolicy permitting tailnet ingress to the destination namespace — without it, kube-router drops the forwarded packet on delphi's FORWARD chain."
  type        = string
  default     = ""
}
