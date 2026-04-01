variable "state_dirs" {
  type = string
}

variable "vault_root_token" {
  type      = string
  sensitive = true
}

variable "headscale_magic_domain" {
  type = string
}

variable "headscale_subdomain" {
  type    = string
  default = "hs"
}

variable "vault_unseal_key" {
  type      = string
  sensitive = true
}

variable "kubeconfig_path" {
  type    = string
  default = "~/.config/kube/config"
}
