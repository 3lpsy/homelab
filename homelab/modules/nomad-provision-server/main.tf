

resource "null_resource" "install_deps" {
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  # Set permissions and optionally run a command
  provisioner "remote-exec" {
    inline = [
      "sudo dnf install -y git nginx neovim wget yq"
    ]
  }
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
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      # Install K3s, change advertise addr if adding nodes over tailscale, maybe node-ip too
      "TAILSCALE_IP=$(tailscale ip -4)",
      "curl -sfL https://get.k3s.io | sh -s - server --write-kubeconfig-mode 640 --node-ip $TAILSCALE_IP  --bind-address $TAILSCALE_IP --tls-san ${var.nomad_host_name}.${var.headscale_magic_subdomain} --node-name ${var.nomad_host_name}.${var.headscale_magic_subdomain}  --flannel-backend=wireguard-native",
      "sudo chown root:provisioner /etc/rancher/k3s/k3s.yaml"
    ]
  }
  depends_on = [null_resource.k3s_prep_firewalld]
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
      "sudo systemctl mask passim.service || echo 'No passim to mask or it failed'"
    ]
  }
  depends_on = [null_resource.k3s_install]
}

resource "null_resource" "k3s_registry_config" {
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
EOF
      EOT
      ,
      "sudo systemctl restart k3s"
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
