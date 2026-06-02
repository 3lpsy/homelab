terraform {
  required_providers {
    headscale = {
      source                = "awlsring/headscale"
      version               = "~>0.5.0"
      configuration_aliases = [headscale]
    }
  }
}

resource "null_resource" "set_hostname" {
  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo hostnamectl set-hostname ${var.nomad_hostname}"

    ]
  }
}
resource "null_resource" "install_tailscale" {
  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo dnf update -y",
      "sudo dnf config-manager addrepo --from-repofile=https://pkgs.tailscale.com/stable/fedora/tailscale.repo",
      "sudo dnf install -y tailscale",
      "sudo systemctl --now enable tailscaled",
    ]
  }
}

resource "null_resource" "upload_auth_key" {
  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "file" {
    content     = var.tailnet_auth_key
    destination = "/home/${var.ssh_user}/tailnet_auth_key"
  }
  depends_on = [null_resource.install_tailscale]
}

resource "null_resource" "tailnet_auth" {
  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      # No --advertise-tags: tag:nomad-server was never declared in tagOwners,
      # so the cluster node is a user node owned by nomad_server_user (→
      # group:node-server in the ACLs). Headscale v0.28 rejects an unowned
      # advertised tag at registration, which would block a fresh join.
      "sudo tailscale up --login-server https://${var.headscale_server_domain} --auth-key file:///home/${var.ssh_user}/tailnet_auth_key --hostname ${var.nomad_hostname} --accept-routes",
      "sudo rm /home/${var.ssh_user}/tailnet_auth_key"
    ]
  }
  depends_on = [null_resource.upload_auth_key]
}

resource "null_resource" "firewall_exclude" {
  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo firewall-cmd --zone=trusted --add-interface=tailscale0 --permanent",
      # Open the direct-path discovery/data port on the PHYSICAL NIC (default
      # zone). Trusting tailscale0 only covers traffic already on the overlay;
      # tailscale's UDP/41641 peer packets arrive on the LAN interface. Two
      # kernel tailscaled hosts symmetric-punch via conntrack and limp to a
      # direct path without this, but a userspace pod sidecar (e.g. the
      # registry ingress) can't — so it stays pinned to DERP, relaying
      # cross-node image pulls through the cloud. Opening 41641/udp lets the
      # sidecar's direct path land on the LAN.
      "sudo firewall-cmd --permanent --add-port=41641/udp",
      "sudo firewall-cmd --reload"
    ]
  }
  depends_on = [null_resource.upload_auth_key]
}

# Apply subnet-route advertisements via `tailscale set` (non-disruptive, no
# re-auth) so we can change advertise_routes without tearing down the
# tailnet_auth resource. Re-runs whenever advertise_routes changes.
#
# Always runs (even when empty) so setting advertise_routes="" actively
# WITHDRAWS a previously-advertised route — `tailscale set --advertise-routes=`
# clears it. (A count-gated resource would just stop managing it, leaving the
# old advertisement live on the node.) Empty is the norm for cluster nodes:
# advertising the pod CIDR is what lets an --accept-routes peer hijack pod
# traffic onto tailscale0 (table 52 > main). Intra-cluster pod routing is
# flannel's; this is only for exposing non-tailnet subnets to the tailnet.
resource "null_resource" "tailnet_advertise_routes" {
  triggers = {
    advertise_routes = var.advertise_routes
  }

  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo tailscale set --advertise-routes=${var.advertise_routes}"
    ]
  }

  depends_on = [null_resource.tailnet_auth]
}

# After the device is registered via tailscale up
data "headscale_device" "nomad_server" {
  name       = var.nomad_hostname # The hostname you set with --hostname flag
  depends_on = [null_resource.tailnet_auth]
}
