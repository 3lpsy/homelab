

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
      "curl -sfL https://get.k3s.io | sh -s - server --write-kubeconfig-mode 640 --node-ip $TAILSCALE_IP  --bind-address $TAILSCALE_IP --tls-san ${var.nomad_host_name}.${var.headscale_magic_subdomain} --node-name ${var.nomad_host_name}.${var.headscale_magic_subdomain}",
      "sudo chown root:provisioner /etc/rancher/k3s/k3s.yaml"
    ]
  }
  depends_on = [null_resource.k3s_prep_firewalld]
}
