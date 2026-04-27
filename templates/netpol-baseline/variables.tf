variable "namespace" {
  description = "Namespace this baseline applies to."
  type        = string
}

variable "pod_cidr" {
  description = "Cluster pod CIDR. Used to exclude pod-internal traffic from internet/API ipBlock allows."
  type        = string
}

variable "service_cidr" {
  description = "Cluster service CIDR. Used to exclude service-internal traffic from internet/API ipBlock allows."
  type        = string
}

variable "allow_internet_egress" {
  description = "If true, allow egress to all non-cluster IPs on TCP/UDP. Required by any pod with a Tailscale sidecar (Headscale + DERP relays) or that fetches external resources (e.g. BuildKit Dockerfile FROMs, exit-node WireGuard tunnels). When false, only DNS + the K8s API (if enabled) are allowed."
  type        = bool
  default     = true
}

variable "allow_kube_api_egress" {
  description = "If true, allow TCP egress to the Kubernetes API on port 6443 (which kube-proxy DNATs from `kubernetes.default.svc:443` to the host). Required by Tailscale sidecars (TS_KUBE_SECRET state), Reloader, kube-state-metrics, mcp-k8s, searxng-ranker, and anything else doing kube-API calls. Disable only if no pod in the namespace touches the API."
  type        = bool
  default     = true
}
