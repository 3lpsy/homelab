variable "state_dirs" {
  type = string
}

variable "ssh_priv_key_path" {
  type = string
}

variable "node_host_name" {
  type = string
}

variable "node_ssh_user" {
  type = string
}

variable "node_server_ip" {
  type = string
}

# ─── artemis: GPU agent node ────────────────────────────────────────────────
# Second K3s node (worker-only). Joins delphi's control plane as an agent.
# See docs/CLUSTER.md.

variable "artemis_host_name" {
  type        = string
  description = "Hostname / headscale node name for the GPU agent node (e.g. \"artemis\"). Joins the tailnet under the same nomad_server_user identity as delphi."
}

variable "artemis_server_ip" {
  type        = string
  description = "LAN IP of artemis, used for the initial SSH/tailscale-join (before the tailnet hostname resolves), mirroring node_server_ip for delphi."
}

variable "k3s_node_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Optional: delphi's K3s server node-token (/var/lib/rancher/k3s/server/node-token), used for artemis's agent join. When set, the cluster plan/apply does NOT SSH delphi to read it — decoupling routine plans from delphi being reachable. When empty (default), it's read live at apply time via data.external.k3s_node_token. Supply out-of-band (TF_VAR_k3s_node_token or the private tfvars at $HOME/Playground/private/envs/homelab/); never commit it."
}

variable "headscale_api_key" {
  type    = string
  default = ""
}

variable "headscale_magic_domain" {
  type = string
}

variable "headscale_subdomain" {
  type    = string
  default = "hs"
}

variable "aws_region" {
  type      = string
  default   = "us-east-1"
  sensitive = true
}

variable "aws_access_key" {
  type      = string
  sensitive = true
}

variable "aws_secret_key" {
  type      = string
  sensitive = true
}

variable "recursive_nameservers" {
  type    = list(string)
  default = ["9.9.9.9", "149.112.112.112"]
}

variable "acme_server_url" {
  type    = string
  default = "https://acme-v02.api.letsencrypt.org/directory"
}

variable "k8s_pod_cidr" {
  description = "K3s pod CIDR (k3s' default `cluster-cidr`). CURRENTLY UNUSED in this deployment: it once fed delphi's advertise_routes, but advertising the pod CIDR let an --accept-routes peer (artemis) hijack all pod traffic onto tailscale0 via policy table 52, breaking cross-node pod<->pod + pod->apiserver — so advertise_routes is now hardcoded \"\" and cross-node pod routing is flannel-wireguard's job. The firewalld trusted-zone rule hardcodes the 10.42.0.0/16 literal rather than reading this var. Retained to document the cluster-cidr value (mirrors services/variables.tf k8s_pod_cidr); safe to drop from cluster/. See docs/CLUSTER.md 'Subnet routes'."
  type        = string
  default     = "10.42.0.0/16"
}

variable "zigbee_dongle_serial" {
  description = "USB serial of the Zigbee coordinator dongle (e.g. ZBT-2). Empty disables the udev rule. See cluster/modules/node-provision-server/variables.tf for details."
  type        = string
  default     = ""
}
