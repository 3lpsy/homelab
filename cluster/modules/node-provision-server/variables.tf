

variable "host" {
  type = string
}
variable "ssh_user" {
  type = string
}
variable "ssh_priv_key" {
  type = string
}
variable "nomad_host_name" {
  type = string
}
# hs.root.com
variable "headscale_magic_subdomain" {
  type = string
}

variable "registry_domain" {
  type = string
}

variable "registry_dockerio_domain" {
  type        = string
  description = "Tailnet hostname for the Docker Hub pull-through cache. Containerd routes docker.io pulls through https://<this>.<magic_subdomain>. Auth is gated at the tailnet layer; no credentials in registries.yaml."
}

variable "registry_ghcrio_domain" {
  type        = string
  description = "Tailnet hostname for the ghcr.io pull-through cache. Containerd routes ghcr.io pulls through https://<this>.<magic_subdomain>. Auth is gated at the tailnet layer; no credentials in registries.yaml."
}

variable "k3s_version" {
  type    = string
  default = "v1.35.3+k3s1"
}
