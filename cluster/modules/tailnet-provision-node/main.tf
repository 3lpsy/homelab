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
      "sudo tailscale up --login-server https://${var.headscale_server_domain} --auth-key file:///home/${var.ssh_user}/tailnet_auth_key --hostname ${var.nomad_hostname} --advertise-tags=tag:nomad-server --accept-routes",
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
      "sudo firewall-cmd --reload"
    ]
  }
  depends_on = [null_resource.upload_auth_key]
}

# Apply subnet-route advertisements via `tailscale set` (non-disruptive, no
# re-auth) so we can change advertise_routes without tearing down the
# tailnet_auth resource. Re-runs whenever advertise_routes changes.
#
# Note: route delivery to specific pods *also* requires NetworkPolicy
# permitting tailnet ingress to the destination namespace. kube-router
# enforces netpols on delphi's FORWARD chain and drops tailnet-sourced
# packets that don't match an explicit allow, so by default this route
# only gets traffic to delphi — not all the way to the pod.
resource "null_resource" "tailnet_advertise_routes" {
  count = var.advertise_routes == "" ? 0 : 1

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
