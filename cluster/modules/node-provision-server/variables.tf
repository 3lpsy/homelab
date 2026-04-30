

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

variable "zigbee_dongle_serial" {
  type        = string
  description = "USB serial of the Zigbee coordinator dongle (e.g. ZBT-2). When set, a udev rule on the K3s node creates a stable /dev/zbt-2 symlink to the underlying char device. Point services/var.homeassist_z2m_usb_device_path at /dev/zbt-2 — that decouples from kubelet's hostPath-plugin bug where it auto-creates an empty directory at /dev/serial/by-id/<name> on a failed mount, blocking udev from recreating the symlink. Find with `udevadm info -q property -n /dev/ttyACM0 | grep ID_SERIAL_SHORT`. Empty disables the rule."
  default     = ""
}
