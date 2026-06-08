

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

# ─── Per-node hardware / role parameters ────────────────────────────────────
# delphi (server) takes the defaults; artemis (GPU agent) overrides them.

variable "enable_coral" {
  type        = bool
  description = "Install the Coral M.2 EdgeTPU DKMS driver (KyleGospo COPR + in-place kernel patches). True on delphi (Frigate detector); false on artemis (no Coral — Frigate's detector moves to the R9700 GPU)."
  default     = true
}

variable "enable_rocm" {
  type        = bool
  description = "Install ROCm userspace (runtime/rocminfo/rocm-smi) for discrete Radeon GPUs. Relies on Fedora's in-tree, kernel-signed amdgpu module — NOT rocm-dkms — because artemis runs with Secure Boot enabled (an unsigned DKMS module wouldn't load). The in-cluster amd.com/gpu device plugin only needs /dev/kfd + /dev/dri from that driver. False on delphi (iGPU only, VAAPI via mesa-freeworld); true on artemis (2× R9700, gfx1201)."
  default     = false
}

variable "enable_lact" {
  type        = bool
  description = "Install LACT (headless) + enable the lactd daemon for AMD GPU telemetry. lactd exposes /run/lactd.sock, which the llm pod (services/llm.tf) mounts so llama-swap's Performance Monitor can read GPU temp/clocks/power/VRAM/util. True on artemis; false on delphi."
  default     = false
}

variable "lact_version" {
  type        = string
  description = "LACT release version (no leading v) for the Fedora RPM. The per-release RPM is resolved with `rpm -E %fedora`; LACT ships fedora-43/44 builds, so the host must be Fedora >= 43. github.com/ilya-zlobintsev/LACT/releases."
  default     = "0.9.0"
}

variable "enable_atlantic_gso_fix" {
  type        = bool
  description = "Install the systemd oneshot that disables tx-udp-segmentation on `atlantic`-driver NICs (Aquantia/Marvell AQC-series). Those NICs ship a broken UDP segmentation offload that collapses WireGuard/tailscale throughput to ~1 MB/s (TCP unaffected). True on artemis (AQC113 10GbE); false on delphi (no atlantic NIC). The script is also driver-detected, so it's a harmless no-op even where enabled on a host without an atlantic NIC."
  default     = false
}

variable "enable_user_namespaces" {
  type        = bool
  description = "Provision a subordinate uid/gid pool for root in /etc/subuid + /etc/subgid, supporting pods that set hostUsers:false (Kubernetes user namespaces). NOTE: with containerd the kubelet allocates host ranges itself, so this is likely a no-op (it's a CRI-O-style requirement); it's harmless and provisioned for completeness."
  default     = false
}

variable "k3s_role" {
  type        = string
  description = "K3s install role. \"server\" = control-plane node that also runs workloads (delphi). \"agent\" = worker-only node that joins an existing server's control plane (artemis). Agents require k3s_server_url + k3s_token."
  default     = "server"

  validation {
    condition     = contains(["server", "agent"], var.k3s_role)
    error_message = "k3s_role must be \"server\" or \"agent\"."
  }
}

variable "k3s_server_url" {
  type        = string
  description = "For k3s_role=\"agent\": the K3s server API URL to join, e.g. https://<server-fqdn>:6443. Ignored for servers."
  default     = ""
}

variable "k3s_token" {
  type        = string
  description = "For k3s_role=\"agent\": the server's node-token (read from /var/lib/rancher/k3s/server/node-token on the server). Ignored for servers."
  default     = ""
  sensitive   = true
}

variable "node_taints" {
  type        = list(string)
  description = "K3s --node-taint entries (repeatable), e.g. [\"gpu=true:NoSchedule\"]. Applied at node registration only — changing post-join needs kubectl. Empty on delphi (server, runs all workloads). Set on artemis so nothing schedules there without an explicit toleration, guarding delphi workloads' node-bound local-path PVCs against an accidental reschedule onto artemis's empty disk. Pods that DO belong on artemis must carry a matching toleration AND a nodeSelector/affinity to it."
  default     = []
}

variable "node_labels" {
  type        = list(string)
  description = "K3s --node-label entries (repeatable), e.g. [\"node=artemis\"]. Like node_taints, applied at node registration ONLY — k3s can't change/re-add them on restart (k3s-io/k3s#10957), so set them at first join; post-join changes need kubectl. The positive counterpart to the taint: artemis-bound workloads target this short label (nodeSelector/affinity) instead of the full-fqdn kubernetes.io/hostname. Empty on delphi (the default untainted node)."
  default     = []
}

# ── NUT (Network UPS Tools) — UPS-triggered graceful shutdown ────────────────
# delphi (USB-connected to the CyberPower UPS) runs the NUT "primary": driver +
# upsd + upsmon. artemis runs the "secondary": upsmon only, monitoring delphi's
# upsd over the LAN. See data/nut/ and the nut_primary / nut_secondary resources.
variable "nut_role" {
  type        = string
  description = "NUT role for this node: \"primary\" (delphi — drives the USB UPS, runs upsd + upsmon), \"secondary\" (artemis — upsmon monitoring the primary over the LAN), or \"none\" (no NUT). Gates the nut_primary / nut_secondary resources."
  default     = "none"
  validation {
    condition     = contains(["primary", "secondary", "none"], var.nut_role)
    error_message = "nut_role must be \"primary\", \"secondary\", or \"none\"."
  }
}

variable "nut_monitor_password" {
  type        = string
  description = "Shared password for the read-only NUT \"upsmon\" user. Lives in upsd.users on the primary and the MONITOR line on both nodes. Same value on both. Empty when nut_role=\"none\"."
  default     = ""
  sensitive   = true
}

variable "nut_primary_host" {
  type        = string
  description = "For nut_role=\"secondary\": host the secondary's upsmon connects to for upsd. Use the primary's LAN IP (not the tailnet FQDN) so the shutdown signal survives a tailscaled hiccup and depends only on the LAN switch. Ignored for primary/none."
  default     = ""
}

variable "nut_allow_sources" {
  type        = list(string)
  description = "For nut_role=\"primary\": source IPs (NUT secondaries) allowed to reach upsd on 3493/tcp. The node runs firewalld (only 6443 + the pod/service CIDRs are open by default), so each secondary needs an explicit allow. One firewalld rich-rule per entry, scoped to the source — NOT a blanket port open. Empty = no remote upsmon (standalone primary)."
  default     = []
}

variable "nut_runtime_low" {
  type        = number
  description = "Seconds of estimated UPS runtime at which to assert LOW BATTERY and begin shutdown (override.battery.runtime.low). 180 = start shutting down with ~3 min left — load-adaptive, ignores short blips. Primary only."
  default     = 180
}

variable "nut_onbatt_backstop_secs" {
  type        = number
  description = "upssched wall-clock backstop (primary only): if on battery this many seconds straight without the UPS ever reporting low battery, force shutdown anyway. 600 = 10 min. Guards against a misreported/stuck runtime reading."
  default     = 600
}
