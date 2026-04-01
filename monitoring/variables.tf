variable "state_dirs" {
  type = string
}


variable "vault_root_token" {
  type = string
}

variable "headscale_subdomain" {
  type    = string
  default = "hs"
}

variable "headscale_magic_domain" {
  type = string
}

variable "headscale_api_key" {
  type      = string
  sensitive = true
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "kubeconfig_path" {
  type = string
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

variable "grafana_domain" {
  type    = string
  default = "grafana"
}

variable "grafana_admin_user" {
  type    = string
  default = "admin"
}

variable "openwrt_domain" {
  type    = string
  default = "openwrt"
}

variable "prometheus_retention" {
  type    = string
  default = "30d"
}

variable "prometheus_storage_size" {
  type    = string
  default = "20Gi"
}

variable "grafana_storage_size" {
  type    = string
  default = "5Gi"
}

variable "ntfy_domain" {
  type    = string
  default = "ntfy"
}

variable "ntfy_users" {
  type = map(string)
  default = {
    grafana    = "admin"
    mobile     = "user"
    prometheus = "user"
  }
}

variable "ntfy_alert_topic" {
  type    = string
  default = "homelab"
}
variable "ntfy_storage_size" {
  type    = string
  default = "2Gi"
}

variable "image_busybox" {
  type    = string
  default = "busybox:latest"
}

variable "image_tailscale" {
  type    = string
  default = "tailscale/tailscale:latest"
}

variable "image_nginx" {
  type    = string
  default = "nginx:alpine"
}

variable "image_prometheus" {
  type    = string
  default = "prom/prometheus:latest"
}

variable "image_node_exporter" {
  type    = string
  default = "prom/node-exporter:latest"
}

variable "image_kube_state_metrics" {
  type    = string
  default = "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.18.0"
}

variable "image_grafana" {
  type    = string
  default = "grafana/grafana:latest"
}

variable "image_ntfy" {
  type    = string
  default = "binwiederhier/ntfy:latest"
}

variable "image_alertmanager" {
  type    = string
  default = "prom/alertmanager:latest"
}

variable "image_python" {
  type    = string
  default = "python:3-alpine"
}
