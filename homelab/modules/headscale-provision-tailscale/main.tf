resource "null_resource" "tailscale_install" {
  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = trimspace(file(var.ssh_priv_key_path))
    timeout     = "2m"
  }

  provisioner "remote-exec" {
    inline = [
      "command -v tailscale >/dev/null 2>&1 || { curl -fsSL https://tailscale.com/install.sh | sudo sh; }",
      "sudo systemctl enable --now tailscaled",
    ]
  }
}

resource "null_resource" "tailscale_up" {
  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = trimspace(file(var.ssh_priv_key_path))
    timeout     = "2m"
  }

  triggers = {
    login_server = var.headscale_server_domain
    hostname     = var.tailnet_hostname
  }

  provisioner "remote-exec" {
    inline = [
      # --accept-dns=true (default) so MagicDNS resolves tailnet FQDNs
      # like openobserve.hs.<magic> for the OTel agent.
      "sudo tailscale up --login-server=https://${var.headscale_server_domain} --authkey='${var.preauth_key}' --hostname='${var.tailnet_hostname}' --ssh --reset",
    ]
  }

  depends_on = [null_resource.tailscale_install]
}
