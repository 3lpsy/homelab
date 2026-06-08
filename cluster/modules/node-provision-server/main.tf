

resource "null_resource" "install_deps" {
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo dnf install -y git nginx neovim wget yq ethtool"
    ]
  }
}

# Fedora ships mesa-va-drivers without the patent-encumbered H.264/HEVC VAAPI
# profiles, which means iGPU hardware decode is unavailable for almost every
# IP camera codec. Swap to mesa-va-drivers-freeworld from RPM Fusion so the
# Frigate pod's ffmpeg can use `preset-vaapi` without falling back to CPU.
# Idempotent: rpmfusion-free-release re-install is a no-op when present, and
# the dnf swap is gated on freeworld not already being installed.
resource "null_resource" "gpu_vaapi" {
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo dnf install -y https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm",
      "rpm -q mesa-va-drivers-freeworld >/dev/null 2>&1 || sudo dnf swap -y mesa-va-drivers mesa-va-drivers-freeworld"
    ]
  }
  depends_on = [null_resource.install_deps]
}

# Coral M.2 PCIe Edge TPU driver. KyleGospo's COPR is the de-facto Fedora
# path; there is no official one. Background: google/gasket-driver was
# archived 2026-04-18 and dropped from kernel staging because Google
# stopped maintaining it. Officially supports Linux < 6.4 only. The COPR
# repackages the dead upstream + community patches; we then sed in the
# kernel-6.13+ MODULE_IMPORT_NS string-literal fix because no fork has
# rolled it in yet. Secure Boot must be off (or MOK signing in place) for
# the unsigned DKMS module to load. Long term Frigate is moving toward
# Hailo (M.2, actively maintained, supported in :stable image without
# driver hacks); when this stops compiling against a future kernel,
# replacing the Coral with a Hailo-8L is the escape hatch.
# Final inline command is a sentinel — fails the resource loudly if the
# device didn't materialise, rather than letting the Frigate pod
# CrashLoop later.
# count parameterizes this for artemis (enable_coral=false → count 0). delphi's
# pre-existing un-indexed instance was migrated to [0] via a moved{} block,
# dropped now that the migration has applied.
resource "null_resource" "coral_dkms" {
  count = var.enable_coral ? 1 : 0

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo dnf install -y dkms kernel-devel-$(uname -r)",
      "sudo dnf copr enable -y kylegospo/google-coral-dkms",
      "sudo dnf install -y gasket-dkms",
      # Linux 6.13 made MODULE_IMPORT_NS() require a string literal
      # (commit cdd30ebb1b9f). The COPR source still ships the old
      # bareword form which fails to compile on kernel 6.13+. Idempotent
      # sed: once patched the substitution becomes a no-op. If/when the
      # COPR ships a fixed build, this line is harmless.
      "sudo sed -i 's/MODULE_IMPORT_NS(DMA_BUF)/MODULE_IMPORT_NS(\"DMA_BUF\")/g' /usr/src/gasket-*/gasket_page_table.c",
      # On F44 / kernel 7.x the COPR source's RHEL guards
      # (`#if defined RHEL_RELEASE_CODE && RHEL_RELEASE_CODE >= RHEL_RELEASE_VERSION(9, X)`)
      # fail to parse on non-RHEL because RHEL_RELEASE_VERSION is undefined,
      # tripping cpp's `missing binary operator` and falling through to the
      # pre-6.4 / pre-6.8 API branch (2-arg class_create, 2-arg eventfd_signal),
      # which doesn't compile against modern kernels. Inject a no-op shim at
      # the top of every file using the macro so the guard parses and short-
      # circuits to the new-API branch. Idempotent via grep guard.
      "for f in $(sudo grep -l RHEL_RELEASE_VERSION /usr/src/gasket-*/*.c /usr/src/gasket-*/*.h 2>/dev/null); do sudo head -3 \"$f\" | grep -q '#ifndef RHEL_RELEASE_VERSION' || sudo sed -i '1i\\#ifndef RHEL_RELEASE_VERSION\\n#define RHEL_RELEASE_VERSION(a,b) 0\\n#endif' \"$f\"; done",
      "sudo dkms autoinstall -k $(uname -r)",
      "sudo modprobe gasket",
      "sudo modprobe apex",
      "sudo udevadm control --reload",
      "sudo udevadm trigger --action=add --subsystem-match=apex",
      "lsmod | grep -E '^(gasket|apex)' && test -c /dev/apex_0"
    ]
  }
  depends_on = [null_resource.install_deps]
}

# AMD ROCm userspace for the discrete Radeon GPUs on artemis (2× R9700,
# RDNA4 gfx1201). The in-cluster amd.com/gpu device plugin (services/) only
# needs a working host driver to detect /dev/kfd + /dev/dri.
#
# Secure Boot is ENABLED on artemis, so we deliberately do NOT install
# rocm-dkms — an unsigned out-of-tree DKMS amdgpu would fail to load without
# MOK enrollment. Fedora's IN-TREE amdgpu module is kernel-signed, loads fine
# under Secure Boot, and already enumerates both cards (rocminfo lists
# gfx1201). So we install ROCm userspace only (runtime + rocminfo + rocm-smi).
# This dnf install is largely a no-op on the current box (those are already
# present) but keeps the host package set declarative and pulls any
# inference/runtime libs we add to the list later.
#
# Final inline command is a sentinel — fails loudly if rocminfo doesn't see
# both gfx1201 GPUs, rather than letting a GPU pod schedule onto a node with a
# broken driver. Run via sudo so it doesn't depend on the render/video group
# membership (added just above) taking effect in this same SSH session.
resource "null_resource" "rocm_install" {
  count = var.enable_rocm ? 1 : 0

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      # Userspace only — NO rocm-dkms (Secure Boot; in-tree amdgpu is used).
      "sudo dnf install -y rocm-runtime rocminfo rocm-smi",
      # Host-side render/video access for the operator's rocm-smi / rocminfo.
      # The device plugin runs as a pod with its own device mounts.
      "sudo usermod -a -G render,video ${var.ssh_user}",
      # Sentinel: both R9700s must enumerate as gfx1201.
      "[ \"$(sudo rocminfo | grep -c gfx1201)\" -ge 2 ]"
    ]
  }
  depends_on = [null_resource.install_deps]
}

# LACT (headless) — AMD GPU telemetry daemon. lactd exposes /run/lactd.sock,
# which the llm pod (services/llm.tf) mounts so llama-swap's Performance
# Monitor can read GPU temp/clocks/power/VRAM/util (its preferred source,
# cleaner than rocm-smi). The headless RPM drops the GTK/GUI deps. The RPM is
# built per Fedora release; `rpm -E %fedora` resolves the host's (LACT ships
# fedora-43/44 for 0.9.0, so artemis must be Fedora >= 43). `triggers` re-runs
# the install when var.lact_version bumps (dnf upgrades the package).
#
# Final inline commands are sentinels — fail loudly if the daemon isn't active
# or the socket is missing, rather than letting the llm pod later wedge on a
# missing hostPath socket (its mount is type=Socket).
resource "null_resource" "lact_install" {
  count = var.enable_lact ? 1 : 0

  triggers = {
    version = var.lact_version
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo dnf install -y \"https://github.com/ilya-zlobintsev/LACT/releases/download/v${var.lact_version}/lact-headless-${var.lact_version}-0.x86_64.fedora-$(rpm -E %fedora).rpm\"",
      "sudo systemctl enable --now lactd",
      # lactd (Type=simple) returns from `start` before it has enumerated the
      # GPUs and created the socket, so poll for it instead of racing with a
      # bare is-active. If it never appears, dump status + journal into the TF
      # output so the failure is diagnosable, then fail.
      "for i in $(seq 1 30); do [ -S /run/lactd.sock ] && break; sleep 1; done",
      "[ -S /run/lactd.sock ] || { sudo systemctl status lactd --no-pager -l; sudo journalctl -u lactd --no-pager -n 50; exit 1; }",
    ]
  }
  depends_on = [null_resource.install_deps]
}

# AMD P-state EPP override. Fedora ships `balance_performance` by default,
# which biases cores toward staying at 2.2-2.6 GHz at light load. On the
# GTR6 (6900HX, small heatsink, aggressive BIOS fan curve) that constant
# baseline freq drove the chassis fan loud even at <10% utilization.
# Switching to `balance_power` lets cores ramp into the hundreds-of-MHz
# range when idle — measured ~25% drop in steady-state Bzy_MHz and
# ~20-30% drop in PkgWatt on a 16-thread sample, with no impact to the
# bursty homelab workload. ConditionPathExists no-ops on non-amd-pstate-epp
# hosts so the unit is safe to ship to any cluster node.
resource "null_resource" "amd_pstate_epp" {
  triggers = {
    epp = "balance_power"
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      <<-EOT
        sudo tee /etc/systemd/system/amd-pstate-epp.service > /dev/null <<'EOF'
[Unit]
Description=Set AMD P-state EPP to balance_power
ConditionPathExists=/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo balance_power | tee /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference >/dev/null'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
      EOT
      ,
      "sudo systemctl daemon-reload",
      "sudo systemctl enable --now amd-pstate-epp.service"
    ]
  }
  depends_on = [null_resource.install_deps]
}

resource "null_resource" "sysctl_inotify" {
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      <<-EOT
        sudo tee /etc/sysctl.d/99-inotify.conf > /dev/null <<'EOF'
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=512
EOF
      EOT
      ,
      "sudo sysctl --system"
    ]
  }
  depends_on = [null_resource.install_deps]
}

# Subordinate uid/gid pool for root → enables pods with hostUsers:false
# (Kubernetes user namespaces). Thin + rerunnable: idempotently rewrites only
# root's line in /etc/subuid + /etc/subgid (the trigger re-runs it if the range
# changes). Likely a no-op under containerd (kubelet allocates its own ranges)
# — kept for completeness; harmless. Gated by var.enable_user_namespaces.
resource "null_resource" "user_namespaces_subid" {
  count = var.enable_user_namespaces ? 1 : 0

  triggers = {
    subid = "root:1048576:1073741824"
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }

  provisioner "remote-exec" {
    inline = [
      "for f in /etc/subuid /etc/subgid; do sudo touch $f; sudo sed -i '/^root:/d' $f; echo '${self.triggers.subid}' | sudo tee -a $f >/dev/null; done",
    ]
  }

  depends_on = [null_resource.install_deps]
}

# Aquantia/Marvell AQC-series NICs on the in-tree `atlantic` driver ship a
# broken UDP segmentation offload. TCP (TSO) hits line rate, but GSO'd UDP
# super-packets get mangled, which collapses any UDP-tunnel throughput —
# WireGuard/tailscale in particular — to ~1 MB/s while plain TCP is fine.
# artemis (ProArt X870E, AQC113 10GbE) hit this hard: every tailnet flow off
# the box, incl. Frigate VOD playback over its tailscale sidecar, was capped
# at ~9.5 Mbps until `tx-udp-segmentation` was disabled, after which it jumped
# to 109 MB/s. Disabling forces software UDP segmentation, which the driver
# handles correctly; the only cost is a little CPU on the (idle) host.
#
# Gated to artemis via var.enable_atlantic_gso_fix (the only box with an AQC
# NIC); count 0 on delphi. The shipped script is ALSO driver-detected as a
# second safety net, so it's a no-op even if enabled on a host without an
# atlantic NIC.
#
# Unit + script are static files in data/scripts/ (no TF interpolation) and
# survive iface renames (detection is by driver, not name). Uploads land in
# the ssh user's home, then `install` places them root:root with correct modes
# (0755 script in /usr/local/sbin, 0644 unit in /etc/systemd/system). filemd5
# triggers a re-upload whenever either file changes.
resource "null_resource" "atlantic_udp_gso_fix" {
  count = var.enable_atlantic_gso_fix ? 1 : 0

  triggers = {
    service = filemd5("${path.root}/../data/scripts/atlantic-udp-gso-fix.service")
    script  = filemd5("${path.root}/../data/scripts/atlantic-udp-gso-fix.sh")
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }

  provisioner "file" {
    source      = "${path.root}/../data/scripts/atlantic-udp-gso-fix.sh"
    destination = "/home/${var.ssh_user}/atlantic-udp-gso-fix.sh"
  }

  provisioner "file" {
    source      = "${path.root}/../data/scripts/atlantic-udp-gso-fix.service"
    destination = "/home/${var.ssh_user}/atlantic-udp-gso-fix.service"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo install -m 0755 -o root -g root /home/${var.ssh_user}/atlantic-udp-gso-fix.sh /usr/local/sbin/atlantic-udp-gso-fix.sh",
      "sudo install -m 0644 -o root -g root /home/${var.ssh_user}/atlantic-udp-gso-fix.service /etc/systemd/system/atlantic-udp-gso-fix.service",
      "rm -f /home/${var.ssh_user}/atlantic-udp-gso-fix.sh /home/${var.ssh_user}/atlantic-udp-gso-fix.service",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable --now atlantic-udp-gso-fix.service",
    ]
  }

  depends_on = [null_resource.install_deps]
}

resource "null_resource" "dnf_automatic" {
  triggers = {
    config = md5(templatefile("${path.root}/../data/server/dnf-automatic.conf.tpl", {}))
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }

  provisioner "file" {
    content     = templatefile("${path.root}/../data/server/dnf-automatic.conf.tpl", {})
    destination = "/home/${var.ssh_user}/automatic.conf"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo dnf install -y dnf-automatic",
      "sudo mv /home/${var.ssh_user}/automatic.conf /etc/dnf/automatic.conf",
      "sudo chown root:root /etc/dnf/automatic.conf",
      "sudo chmod 644 /etc/dnf/automatic.conf",
      "sudo systemctl enable --now dnf-automatic.timer",
    ]
  }

  depends_on = [null_resource.install_deps]
}

# Firewall step 1 — base K3s ports: apiserver + trust the pod/service CIDRs.
resource "null_resource" "k3s_prep_firewalld" {
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      # Configure firewalld for K3s
      "sudo firewall-cmd --permanent --add-port=6443/tcp",
      "sudo firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16",
      "sudo firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16",
      "sudo firewall-cmd --reload"
    ]
  }
  depends_on = [null_resource.install_deps]
}

# Firewall step 2 — NUT upsd reachability (primary only): admit 3493/tcp from the
# allowed sources (firewalld default-denies). Sequenced AFTER k3s_prep_firewalld
# so the two firewall steps don't race on --reload. Just the rich-rules; nut_primary
# installs configs + manages services and no longer touches the firewall.
resource "null_resource" "firewalld_nut" {
  count = var.nut_role == "primary" && length(var.nut_allow_sources) > 0 ? 1 : 0

  triggers = {
    sources = join(",", var.nut_allow_sources)
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = concat(local.nut_firewall_cmds, ["sudo firewall-cmd --reload"])
  }
  depends_on = [null_resource.k3s_prep_firewalld]
}

# NOTE: agent pods reach the apiserver (and any pod→tailnet-node-IP) fine via
# flannel's own FLANNEL-POSTRTG masquerade — no custom SNAT rule is needed. The
# real multi-node gotcha was the pod CIDR being advertised as a tailscale subnet
# route + accepted on the agent, which hijacked pod traffic onto tailscale0. The
# fix lives in homelab/cluster (don't advertise the pod CIDR), not here. See
# docs/CLUSTER.md.

locals {
  k3s_node_fqdn = "${var.nomad_host_name}.${var.headscale_magic_subdomain}"

  # Node taints (k3s --node-taint, repeatable). Empty on delphi (server, runs
  # every workload); artemis gets gpu=true:NoSchedule so NOTHING schedules
  # there without an explicit toleration. This guards every delphi workload's
  # node-bound local-path PVC against an accidental reschedule onto artemis's
  # empty disk — deny-by-default at the node beats whitelisting affinity onto
  # ~40 pods. NOTE: --node-taint applies at node *registration* only (exactly
  # when a fresh agent joins); changing it post-join needs kubectl, not apply.
  k3s_taint_args = join(" ", [for t in var.node_taints : "--node-taint ${t}"])

  # Node labels (k3s --node-label, repeatable) — same registration-only
  # constraint as taints. The positive counterpart: artemis carries
  # node=artemis so workloads target it by a short label, not the full-fqdn
  # kubernetes.io/hostname.
  k3s_label_args = join(" ", [for l in var.node_labels : "--node-label ${l}"])

  # K3s install command, branched by role:
  #   server = control-plane node that also runs workloads (delphi). Binds the
  #            API to the tailscale IP, advertises the fqdn as a tls-san, and
  #            owns flannel + the disable flags.
  #   agent  = worker-only node that joins the server's control plane via
  #            K3S_URL + K3S_TOKEN (artemis). It inherits flannel-backend,
  #            tls config, and disable flags from the server, so it only needs
  #            --node-ip / --node-name / --kubelet-arg.
  # INSTALL_K3S_FORCE_RESTART makes re-runs honor changed flags on an existing
  # node. Kubelet Graceful Node Shutdown is NOT set here — it's applied out-of-band
  # by null_resource.k3s_graceful_shutdown (config drop-in + restart) so changing
  # it never forces a reinstall/re-join.
  k3s_install_cmd = var.k3s_role == "server" ? (
    trimspace("curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${var.k3s_version} INSTALL_K3S_FORCE_RESTART=true sh -s - server --write-kubeconfig-mode 640 --node-ip $TAILSCALE_IP --bind-address $TAILSCALE_IP --tls-san ${local.k3s_node_fqdn} --node-name ${local.k3s_node_fqdn} --flannel-backend=wireguard-native --disable=traefik --disable=servicelb --kubelet-arg=resolv-conf=/etc/k3s-resolv.conf ${local.k3s_taint_args} ${local.k3s_label_args}")
    ) : (
    trimspace("curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${var.k3s_version} K3S_URL=${var.k3s_server_url} K3S_TOKEN=${var.k3s_token} INSTALL_K3S_FORCE_RESTART=true sh -s - agent --node-ip $TAILSCALE_IP --node-name ${local.k3s_node_fqdn} --kubelet-arg=resolv-conf=/etc/k3s-resolv.conf ${local.k3s_taint_args} ${local.k3s_label_args}")
  )

  # systemd unit name differs by role (k3s vs k3s-agent).
  k3s_unit = var.k3s_role == "server" ? "k3s" : "k3s-agent"
}

# Step 1 — curated kubelet resolv-conf. systemd-resolved's aggregated
# /run/systemd/resolve/resolv.conf carries globals (9.9.9.9, 1.1.1.1) plus
# tailscale0 v4+v6 MagicDNS, exceeding glibc MAXNS=3 and tripping DNSConfigForming
# on Default / ClusterFirstWithHostNet pods. The install command points kubelet
# at this 3-line file via --kubelet-arg=resolv-conf, so it must exist first.
resource "null_resource" "k3s_resolv_conf" {
  triggers = {
    resolv = "9.9.9.9,1.1.1.1,100.100.100.100"
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      <<-EOT
        sudo tee /etc/k3s-resolv.conf > /dev/null <<'EOF'
nameserver 9.9.9.9
nameserver 1.1.1.1
nameserver 100.100.100.100
EOF
      EOT
    ]
  }
  depends_on = [null_resource.install_deps]
}

# Step 2 — the k3s install/join itself. Just compute the tailscale IP and run the
# installer; everything else (DNS, kubeconfig perms, graceful shutdown) is its
# own resource. Trigger keys on version + (agent) server URL only — NOT the
# token (sensitive, rotates only on a server reinstall) and NOT graceful-shutdown
# (decoupled), so routine config changes don't force a re-join.
resource "null_resource" "k3s_install" {
  triggers = {
    install_args = var.k3s_role == "server" ? "${var.k3s_version}-disable-traefik-servicelb-resolv-conf" : "${var.k3s_version}-agent-${var.k3s_server_url}"
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "TAILSCALE_IP=$(tailscale ip -4)",
      local.k3s_install_cmd,
    ]
  }
  depends_on = [null_resource.k3s_resolv_conf, null_resource.k3s_prep_firewalld]
}

# Step 3 — make the kubeconfig readable by the provisioner group (servers only;
# agents have no /etc/rancher/k3s/k3s.yaml).
resource "null_resource" "k3s_kubeconfig_perms" {
  count = var.k3s_role == "server" ? 1 : 0

  triggers = {
    perms = "root:provisioner-640"
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo chown root:provisioner /etc/rancher/k3s/k3s.yaml",
    ]
  }
  depends_on = [null_resource.k3s_install]
}

# Step 4 — Kubelet Graceful Node Shutdown, applied OUT-OF-BAND from the installer.
#
# GA since k8s 1.21 (feature gate on by default, inert only because the grace
# periods default to 0). Non-zero periods make kubelet register a systemd-logind
# inhibitor: on `systemctl poweroff` (what NUT's SHUTDOWNCMD runs) logind fires
# PrepareForShutdown and kubelet SIGTERMs every pod in priority order — Vault
# steps down + seals, Postgres flushes — quiescing local-path PVC writes BEFORE
# the fs unmounts. That's the fix for the prior power-yank Vault corruption.
#
# shutdownGracePeriod* are KubeletConfiguration fields with NO command-line flag
# (k3s-io/k3s#4319), so they live in a KubeletConfiguration file that we point
# kubelet at via a k3s config.yaml.d drop-in. NOTE the `kubelet-arg+:` APPEND
# key: a plain `kubelet-arg:` would be OVERWRITTEN by the install command's CLI
# --kubelet-arg=resolv-conf (k3s: CLI overwrites config-file list values), which
# would silently drop our config= and leave graceful shutdown inert. The `+`
# appends instead, so resolv-conf AND config= both apply. Delivered here, NOT in
# the install command, so a change is a plain `systemctl restart` (uses stored
# node creds, never the join token) instead of a reinstall/re-join.
resource "null_resource" "k3s_graceful_shutdown" {
  triggers = {
    config = "shutdownGracePeriod=90s,critical=30s"
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p /etc/rancher/k3s/config.yaml.d",
      <<-EOT
        sudo tee /etc/rancher/k3s/kubelet.config > /dev/null <<'EOF'
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
shutdownGracePeriod: 90s
shutdownGracePeriodCriticalPods: 30s
EOF
      EOT
      ,
      <<-EOT
        sudo tee /etc/rancher/k3s/config.yaml.d/90-graceful-shutdown.yaml > /dev/null <<'EOF'
kubelet-arg+:
  - "config=/etc/rancher/k3s/kubelet.config"
EOF
      EOT
      ,
      "sudo systemctl restart ${local.k3s_unit}",
    ]
  }
  # After k3s_registry_config so the two k3s-restarting steps serialize.
  depends_on = [null_resource.k3s_install, null_resource.k3s_registry_config]
}

# Sentinel files prevent the k3s helm-controller from re-deploying the bundled
# traefik HelmCharts on subsequent restarts. Combined with --disable=traefik
# above, this fully removes the install-Job ServiceAccounts and their
# cluster-admin ClusterRoleBindings (Kubescape C-0187, C-0015).
# count gates this to servers (agents have no helm-controller → count 0). delphi's
# pre-existing un-indexed instance was migrated to [0] via a moved{} block,
# dropped now that the migration has applied.
resource "null_resource" "k3s_skip_bundled_charts" {
  # The bundled-chart manifests dir (/var/lib/rancher/k3s/server/manifests)
  # only exists on servers; agents have no helm-controller.
  count = var.k3s_role == "server" ? 1 : 0

  triggers = {
    charts = "traefik-traefik-crd"
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo touch /var/lib/rancher/k3s/server/manifests/traefik.yaml.skip",
      "sudo touch /var/lib/rancher/k3s/server/manifests/traefik-crd.yaml.skip"
    ]
  }

  depends_on = [null_resource.k3s_install]
}

resource "null_resource" "post_k3s_install" {
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo systemctl disable --now avahi-daemon || echo 'No Avahi daemon to disable or it failed'",
      "sudo systemctl disable --now avahi-daemon.socket || echo 'No avahi socket to disable or it failed'",
      "sudo systemctl mask avahi-daemon.service avahi-daemon.socket || echo 'No avahi to mask or it failed'",
      "sudo systemctl stop passim.service || echo 'No passim to stop or it failed'",
      "sudo systemctl mask passim.service || echo 'No passim to mask or it failed'",
      # ModemManager AT-probes any USB CDC-ACM device on enumeration. That
      # races zigbee2mqtt's first ASH frame to the ZBT-2 EmberZNet NCP and
      # leaves the dongle in a state where it never replies → ASH-reset loop
      # → HOST_FATAL_ERROR. Masking is the canonical fix per Z2M's docs.
      "sudo systemctl disable --now ModemManager.service || echo 'No ModemManager to disable or it failed'",
      "sudo systemctl mask ModemManager.service || echo 'No ModemManager to mask or it failed'"
    ]
  }
  depends_on = [null_resource.k3s_install]
}

resource "null_resource" "k3s_registry_config" {
  # Re-run when the rendered registries.yaml content would change.
  triggers = {
    registry_domain          = var.registry_domain
    registry_dockerio_domain = var.registry_dockerio_domain
    registry_ghcrio_domain   = var.registry_ghcrio_domain
    magic_subdomain          = var.headscale_magic_subdomain
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }

  provisioner "remote-exec" {
    inline = [
      # /etc/rancher/k3s exists on servers (holds k3s.yaml) but NOT on a fresh
      # agent, so create it before writing registries.yaml — otherwise tee
      # fails with "No such file or directory" and the file is silently skipped.
      "sudo mkdir -p /etc/rancher/k3s",
      <<-EOT
        sudo tee /etc/rancher/k3s/registries.yaml > /dev/null <<'EOF'
mirrors:
  "${var.registry_domain}.${var.headscale_magic_subdomain}":
    endpoint:
      - "https://${var.registry_domain}.${var.headscale_magic_subdomain}"
  "docker.io":
    endpoint:
      - "https://${var.registry_dockerio_domain}.${var.headscale_magic_subdomain}"
      - "https://registry-1.docker.io"
  "ghcr.io":
    endpoint:
      - "https://${var.registry_ghcrio_domain}.${var.headscale_magic_subdomain}"
      - "https://ghcr.io"
EOF
      EOT
      ,
      # registries.yaml is per-node containerd config (agents read it too);
      # the systemd unit differs by role (k3s vs k3s-agent).
      "sudo systemctl restart ${local.k3s_unit}"
    ]
  }

  depends_on = [null_resource.k3s_install]
}


# Stable host-managed symlink for the Zigbee coordinator dongle (ZBT-2 et al).
# Decouples from kubelet's hostPath plugin bug: kubelet auto-creates an empty
# directory at any non-existing source path during pod mount setup, so a
# failed mount against /dev/serial/by-id/<name> leaves a directory behind
# that blocks udev from recreating the symlink on the next dongle replug
# until the directory is rmdir'd by hand. Pointing TF's
# homeassist_z2m_usb_device_path at /dev/zbt-2 (this rule's symlink target)
# sidesteps the race entirely — kubelet never touches the by-id path, and
# udev re-creates /dev/zbt-2 every plug. Gated on var.zigbee_dongle_serial
# so nodes without a dongle skip the rule.
resource "null_resource" "udev_zigbee_dongle" {
  count = var.zigbee_dongle_serial != "" ? 1 : 0

  triggers = {
    serial = var.zigbee_dongle_serial
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
        sudo tee /etc/udev/rules.d/99-zigbee-dongle.rules > /dev/null <<EOF
SUBSYSTEM=="tty", ATTRS{serial}=="${var.zigbee_dongle_serial}", SYMLINK+="zbt-2", MODE="0660", GROUP="dialout"
EOF
      EOT
      ,
      "sudo udevadm control --reload",
      "sudo udevadm trigger --action=add"
    ]
  }

  depends_on = [null_resource.k3s_install]
}

resource "null_resource" "dns_override" {
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }

  provisioner "remote-exec" {
    inline = [
      # resolved.conf.d override — public DNS as default
      "sudo mkdir -p /etc/systemd/resolved.conf.d",
      <<-EOT
        sudo tee /etc/systemd/resolved.conf.d/override.conf > /dev/null <<'EOF'
[Resolve]
DNS=9.9.9.9 1.1.1.1
Domains=~.
EOF
      EOT
      ,
      # Stop NetworkManager pushing DHCP DNS into systemd-resolved.
      # k3s kubelet uses /run/systemd/resolve/resolv.conf which aggregates
      # all uplinks; per-link DHCP DNS pushed every >3 nameservers and
      # tripped the libc cap (DNSConfigForming warnings on hostNetwork
      # pods + non-cluster-DNS pods like coredns w/ dnsPolicy=Default).
      "sudo mkdir -p /etc/NetworkManager/conf.d",
      <<-EOT
        sudo tee /etc/NetworkManager/conf.d/00-no-dns-push.conf > /dev/null <<'EOF'
[main]
dns=none
EOF
      EOT
      ,
      "sudo systemctl reload NetworkManager",
      "sudo systemctl restart systemd-resolved",

      # Systemd service to scope tailscale0 to magic domain only
      <<-EOT
        sudo tee /etc/systemd/system/fix-tailscale-dns.service > /dev/null <<'EOF'
[Unit]
Description=Scope tailscale DNS to magic domain only
After=tailscaled.service
Requires=tailscaled.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/resolvectl domain tailscale0 ${var.headscale_magic_subdomain}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
      EOT
      ,
      "sudo systemctl daemon-reload",
      "sudo systemctl enable --now fix-tailscale-dns.service"
    ]
  }

  depends_on = [null_resource.k3s_install]
}

locals {
  # One firewalld rich-rule per allowed secondary: admit 3493/tcp from that
  # source only. The node default-denies (firewalld); upsd LISTENs on 0.0.0.0 but
  # only these sources get through. Scoped, not a blanket --add-port.
  nut_firewall_cmds = [
    for s in var.nut_allow_sources :
    "sudo firewall-cmd --permanent --add-rich-rule='rule family=\"ipv4\" source address=\"${s}\" port port=\"3493\" protocol=\"tcp\" accept'"
  ]
}

# ── NUT primary (delphi) ─────────────────────────────────────────────────────
# Drives the USB-connected CyberPower UPS, runs upsd (serving the LAN) and upsmon
# (primary). On a sustained outage it asserts FSD at ~3 min remaining runtime (or
# the upssched wall-clock backstop), which propagates to the secondary then halts
# delphi last. The graceful pod-termination part is kubelet's shutdown inhibitor
# (null_resource.k3s_graceful_shutdown) — SHUTDOWNCMD here is just `poweroff`.
#
# Fedora 44's nut (2.8.4) uses /etc/ups, not /etc/nut (asserted below). Files
# carrying the monitor password (upsd.users, upsmon.conf) install 0640 root:nut
# so the nut-run daemons can read them without world-exposing the secret.
resource "null_resource" "nut_primary" {
  count = var.nut_role == "primary" ? 1 : 0

  triggers = {
    nut_conf       = md5(templatefile("${path.root}/../data/nut/nut.conf.tpl", { mode = "netserver" }))
    ups_conf       = md5(templatefile("${path.root}/../data/nut/ups.conf.tpl", { runtime_low = var.nut_runtime_low }))
    upsd_conf      = md5(file("${path.root}/../data/nut/upsd.conf.tpl"))
    upsd_users     = md5(templatefile("${path.root}/../data/nut/upsd.users.tpl", { monitor_password = var.nut_monitor_password }))
    upsmon_conf    = md5(templatefile("${path.root}/../data/nut/upsmon-primary.conf.tpl", { monitor_password = var.nut_monitor_password }))
    upssched_conf  = md5(templatefile("${path.root}/../data/nut/upssched.conf.tpl", { onbatt_backstop_secs = var.nut_onbatt_backstop_secs }))
    upssched_cmd   = md5(file("${path.root}/../data/nut/upssched-cmd.tpl"))
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }

  provisioner "file" {
    content     = templatefile("${path.root}/../data/nut/nut.conf.tpl", { mode = "netserver" })
    destination = "/home/${var.ssh_user}/nut.conf"
  }
  provisioner "file" {
    content     = templatefile("${path.root}/../data/nut/ups.conf.tpl", { runtime_low = var.nut_runtime_low })
    destination = "/home/${var.ssh_user}/ups.conf"
  }
  provisioner "file" {
    content     = file("${path.root}/../data/nut/upsd.conf.tpl")
    destination = "/home/${var.ssh_user}/upsd.conf"
  }
  provisioner "file" {
    content     = templatefile("${path.root}/../data/nut/upsd.users.tpl", { monitor_password = var.nut_monitor_password })
    destination = "/home/${var.ssh_user}/upsd.users"
  }
  provisioner "file" {
    content     = templatefile("${path.root}/../data/nut/upsmon-primary.conf.tpl", { monitor_password = var.nut_monitor_password })
    destination = "/home/${var.ssh_user}/upsmon.conf"
  }
  provisioner "file" {
    content     = templatefile("${path.root}/../data/nut/upssched.conf.tpl", { onbatt_backstop_secs = var.nut_onbatt_backstop_secs })
    destination = "/home/${var.ssh_user}/upssched.conf"
  }
  provisioner "file" {
    content     = file("${path.root}/../data/nut/upssched-cmd.tpl")
    destination = "/home/${var.ssh_user}/upssched-cmd"
  }

  # Install packages + config files. Firewall is firewalld_nut; this resource
  # does not touch it.
  provisioner "remote-exec" {
    inline = [
      "sudo dnf install -y nut nut-client",
      # The nut pkg creates the nut user+group; guard the group so the 0640
      # root:nut installs below never race a packaging quirk.
      "getent group nut >/dev/null 2>&1 || sudo groupadd -r nut",
      # Confirmed confdir on Fedora 44 / nut 2.8.4 is /etc/ups. Assert it so a
      # future release that moves to /etc/nut fails loudly here (one-line path
      # fix) instead of silently installing configs the daemons never read.
      "test -d /etc/ups || { echo 'ERROR: NUT confdir /etc/ups missing — Fedora may have moved to /etc/nut; update data/nut install paths + CMDSCRIPT' >&2; exit 1; }",
      "sudo install -m 0644 -o root -g root /home/${var.ssh_user}/nut.conf      /etc/ups/nut.conf",
      "sudo install -m 0644 -o root -g root /home/${var.ssh_user}/ups.conf      /etc/ups/ups.conf",
      "sudo install -m 0644 -o root -g root /home/${var.ssh_user}/upsd.conf     /etc/ups/upsd.conf",
      "sudo install -m 0640 -o root -g nut  /home/${var.ssh_user}/upsd.users    /etc/ups/upsd.users",
      "sudo install -m 0640 -o root -g nut  /home/${var.ssh_user}/upsmon.conf   /etc/ups/upsmon.conf",
      "sudo install -m 0644 -o root -g root /home/${var.ssh_user}/upssched.conf /etc/ups/upssched.conf",
      "sudo install -m 0755 -o root -g root /home/${var.ssh_user}/upssched-cmd  /etc/ups/upssched-cmd",
      "rm -f /home/${var.ssh_user}/nut.conf /home/${var.ssh_user}/ups.conf /home/${var.ssh_user}/upsd.conf /home/${var.ssh_user}/upsd.users /home/${var.ssh_user}/upsmon.conf /home/${var.ssh_user}/upssched.conf /home/${var.ssh_user}/upssched-cmd",
      "command -v restorecon >/dev/null 2>&1 && sudo restorecon -Rv /etc/ups || true",
      # Grant the nut group access to ANY CyberPower (vendor 0764) USB device so
      # the nut-user usbhid-ups driver can open it. NUT's shipped rules are
      # per-productid; this vendor-wide rule is productid-agnostic so a hardware
      # revision can't lock us out. nut_udev reloads + triggers udev after this.
      <<-EOT
        sudo tee /etc/udev/rules.d/62-cyberpower-nut.rules > /dev/null <<'EOF'
ACTION=="add|change", SUBSYSTEM=="usb", ATTR{idVendor}=="0764", MODE="0660", GROUP="nut"
EOF
      EOT
      ,
      "command -v restorecon >/dev/null 2>&1 && sudo restorecon -v /etc/udev/rules.d/62-cyberpower-nut.rules || true",
    ]
  }

  depends_on = [null_resource.install_deps]
}

# NUT's udev rule (shipped by the nut package) chowns the UPS USB node to group
# `nut` so the nut-user driver can open it. But the rule only fires on a plug
# EVENT — a UPS already connected when nut installs keeps its default root:root
# node, so usbhid-ups (running as nut) gets "insufficient permissions" and
# crash-loops. Reload + re-trigger udev so the rule applies to the connected
# device. Sequenced AFTER nut_primary (rules present) and BEFORE the driver
# starts (nut_primary_service).
resource "null_resource" "nut_udev" {
  count = var.nut_role == "primary" ? 1 : 0

  # Re-trigger when the package/config set changes (new id) so a reprovision
  # re-applies the device perms before services restart.
  triggers = {
    config = null_resource.nut_primary[0].id
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo udevadm control --reload-rules",
      "sudo udevadm trigger --action=add --subsystem-match=usb",
    ]
  }
  depends_on = [null_resource.nut_primary]
}

# Load the local SELinux module from data/nut/nut-upsmon-local.te. Fedora 44's
# shipped nut policy is incomplete for the shutdown path (upsmon pidfile in
# /run/nut, upsdrvctl killpower access, upssched executing the CMDSCRIPT) — the
# .te carries the harvested rules. Runs on BOTH primary AND secondary: the
# secondary runs upsmon too and needs nut_upsmon_t dac_override for its pidfile
# (the upsd/upsdrvctl rules are inert there — those domains never run, but the
# types exist in the base policy so the module still compiles). Loaded before the
# daemons start (nut_primary_service / nut_secondary depend on this). The .te only
# references base-policy types, so it doesn't need the nut package present —
# depends only on install_deps. checkmodule/semodule_package from checkpolicy;
# semodule from policycoreutils.
resource "null_resource" "nut_selinux" {
  count = var.nut_role != "none" ? 1 : 0

  triggers = {
    policy = md5(file("${path.root}/../data/nut/nut-upsmon-local.te"))
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "file" {
    content     = file("${path.root}/../data/nut/nut-upsmon-local.te")
    destination = "/home/${var.ssh_user}/nut-upsmon-local.te"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo dnf install -y checkpolicy policycoreutils",
      "checkmodule -M -m -o /tmp/nut-upsmon-local.mod /home/${var.ssh_user}/nut-upsmon-local.te",
      "semodule_package -o /tmp/nut-upsmon-local.pp -m /tmp/nut-upsmon-local.mod",
      "sudo semodule -i /tmp/nut-upsmon-local.pp",
      "rm -f /home/${var.ssh_user}/nut-upsmon-local.te /tmp/nut-upsmon-local.mod /tmp/nut-upsmon-local.pp",
    ]
  }
  depends_on = [null_resource.install_deps]
}

# Start/enable the NUT daemons. Split from nut_primary so it runs AFTER nut_udev
# (device accessible) and firewalld_nut (port open). Driver first:
# nut-driver-enumerator (oneshot) reads ups.conf and enables the per-UPS
# nut-driver@cyberpower instance upsd needs; re-run so ups.conf edits regenerate
# it. Restarts whenever the config set changes (keyed on nut_primary's id).
resource "null_resource" "nut_primary_service" {
  count = var.nut_role == "primary" ? 1 : 0

  triggers = {
    config = null_resource.nut_primary[0].id
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo systemctl daemon-reload",
      "sudo systemctl enable --now nut-driver-enumerator.service",
      "sudo systemctl restart nut-driver-enumerator.service",
      "sudo systemctl enable --now nut-server.service nut-monitor.service",
      "sudo systemctl restart nut-server.service nut-monitor.service",
      # nut.target ties the set together for reliable start on boot (Fedora's
      # nut-server enable alone has been flaky across reboots).
      "sudo systemctl enable nut.target 2>/dev/null || true",
      # Best-effort: cut UPS load at end of OS halt so outlets re-energize on grid
      # return (needs BIOS restore-on-AC=on). Absent on some Fedora builds — the
      # graceful shutdown doesn't depend on it, so don't fail the apply.
      "sudo systemctl enable nutshutdown.service 2>/dev/null || true",
    ]
  }
  depends_on = [null_resource.nut_udev, null_resource.nut_selinux, null_resource.firewalld_nut]
}

# ── NUT secondary (artemis) ──────────────────────────────────────────────────
# No UPS of its own — upsmon monitors the primary's upsd over the LAN IP
# (nut_primary_host). Comms loss is NOCOMM-only (never a shutdown trigger); it
# powers off only on an observed OB+LB / the primary's FSD. See
# data/nut/upsmon-secondary.conf.tpl.
resource "null_resource" "nut_secondary" {
  count = var.nut_role == "secondary" ? 1 : 0

  triggers = {
    nut_conf    = md5(templatefile("${path.root}/../data/nut/nut.conf.tpl", { mode = "netclient" }))
    upsmon_conf = md5(templatefile("${path.root}/../data/nut/upsmon-secondary.conf.tpl", { monitor_password = var.nut_monitor_password, primary_host = var.nut_primary_host }))
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }

  provisioner "file" {
    content     = templatefile("${path.root}/../data/nut/nut.conf.tpl", { mode = "netclient" })
    destination = "/home/${var.ssh_user}/nut.conf"
  }
  provisioner "file" {
    content     = templatefile("${path.root}/../data/nut/upsmon-secondary.conf.tpl", { monitor_password = var.nut_monitor_password, primary_host = var.nut_primary_host })
    destination = "/home/${var.ssh_user}/upsmon.conf"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo dnf install -y nut-client",
      "getent group nut >/dev/null 2>&1 || sudo groupadd -r nut",
      "test -d /etc/ups || { echo 'ERROR: NUT confdir /etc/ups missing — Fedora may have moved to /etc/nut; update data/nut install paths' >&2; exit 1; }",
      "sudo install -m 0644 -o root -g root /home/${var.ssh_user}/nut.conf    /etc/ups/nut.conf",
      "sudo install -m 0640 -o root -g nut  /home/${var.ssh_user}/upsmon.conf /etc/ups/upsmon.conf",
      "rm -f /home/${var.ssh_user}/nut.conf /home/${var.ssh_user}/upsmon.conf",
      "command -v restorecon >/dev/null 2>&1 && sudo restorecon -Rv /etc/ups || true",
      "sudo systemctl daemon-reload",
      # netclient: only upsmon runs here — no upsd, no driver, no inbound port
      # (outbound to the primary's LAN 3493 is allowed by default). No firewall
      # change needed on the secondary.
      "sudo systemctl enable --now nut-monitor.service",
      "sudo systemctl restart nut-monitor.service",
    ]
  }

  # nut_selinux before this so the upsmon pidfile (dac_override) policy is active
  # when nut-monitor starts here.
  depends_on = [null_resource.install_deps, null_resource.nut_selinux]
}
