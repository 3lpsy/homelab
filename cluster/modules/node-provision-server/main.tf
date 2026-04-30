

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
      "sudo dnf install -y git nginx neovim wget yq"
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



resource "null_resource" "k3s_install" {
  triggers = {
    install_args = "${var.k3s_version}-disable-traefik-servicelb"
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
      # Install K3s, change advertise addr if adding nodes over tailscale, maybe node-ip too.
      # INSTALL_K3S_FORCE_RESTART makes re-runs honor changed flags on an existing node.
      "TAILSCALE_IP=$(tailscale ip -4)",
      "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${var.k3s_version} INSTALL_K3S_FORCE_RESTART=true sh -s - server --write-kubeconfig-mode 640 --node-ip $TAILSCALE_IP --bind-address $TAILSCALE_IP --tls-san ${var.nomad_host_name}.${var.headscale_magic_subdomain} --node-name ${var.nomad_host_name}.${var.headscale_magic_subdomain} --flannel-backend=wireguard-native --disable=traefik --disable=servicelb",
      "sudo chown root:provisioner /etc/rancher/k3s/k3s.yaml"
    ]
  }
  depends_on = [null_resource.k3s_prep_firewalld]
}

# Sentinel files prevent the k3s helm-controller from re-deploying the bundled
# traefik HelmCharts on subsequent restarts. Combined with --disable=traefik
# above, this fully removes the install-Job ServiceAccounts and their
# cluster-admin ClusterRoleBindings (Kubescape C-0187, C-0015).
resource "null_resource" "k3s_skip_bundled_charts" {
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
      "sudo systemctl restart k3s"
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
