variable "state_dirs" {
  type = string
}

variable "kubeconfig_path" {
  type    = string
  default = "~/.config/kube/config"
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

variable "headscale_api_key" {
  type    = string
  default = ""
}

variable "headscale_server_domain" {
  type = string
}

variable "headscale_magic_domain" {
  type = string
}

variable "headscale_subdomain" {
  type    = string
  default = "hs"
}

variable "acme_server_url" {
  type    = string
  default = "https://acme-v02.api.letsencrypt.org/directory"
}

variable "recursive_nameservers" {
  type    = list(string)
  default = ["9.9.9.9", "149.112.112.112"]
}

variable "vault_server_host_name" {
  type = string
}

variable "vault_unseal_key" {
  type      = string
  sensitive = true
  default   = "placeholder" # Needs to be updated in vault-conf post apply
}

# Container images

variable "image_vault" {
  type    = string
  # Pinned to 1.21.4 (current 1.21.x stable). 1.21 made sys/rekey and
  # sys/generate-root authenticated by default — sys/unseal (used by our
  # auto-unseal sidecar) is unaffected. KV v2 GUI bug in 1.21.0/.1, so
  # stay on 1.21.2+.
  default = "hashicorp/vault:1.21.4"
}

variable "image_busybox" {
  type    = string
  default = "busybox:latest"
}

variable "image_tailscale" {
  type    = string
  default = "tailscale/tailscale:latest"
}

# Digest-pinned sidecar images for the bootstrap-critical Vault pod. With
# image_pull_policy=IfNotPresent these start from the containerd cache on
# reboot without needing a registry/mirror — Vault is the cluster's init gate,
# so it must not depend on anything pullable. Floating vars above stay floating.
variable "image_busybox_pinned" {
  type    = string
  default = "busybox:1.38.0@sha256:fd8d9aa63ba2f0982b5304e1ee8d3b90a210bc1ffb5314d980eb6962f1a9715d"
}

variable "image_tailscale_pinned" {
  type    = string
  default = "tailscale/tailscale:v1.98.4@sha256:25cde9ad76020b0e29229136d0c38b5962e9a0e1774ffac9b0df68e4a37d6cf0"
}

variable "k8s_pod_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "k8s_service_cidr" {
  type    = string
  default = "10.43.0.0/16"
}
