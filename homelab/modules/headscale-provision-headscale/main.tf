

resource "null_resource" "main" {
  # # Triggers to ensure the resource runs when the certificates change
  # triggers = {
  #   fullchain_pem = md5(var.tls_fullchain_pem)
  #   privkey_pem   = md5(var.tls_privkey_pem)
  # }

  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }

  provisioner "file" {
    content = templatefile("${path.root}/../data/config.yaml.tpl", {
      server_domain = var.headscale_server_domain
      server_port   = var.headscale_port
      magic_domain  = var.headscale_magic_domain
    })
    destination = "/home/${var.ssh_user}/config.yaml"
  }


  # Set permissions and optionally run a command
  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p /etc/headscale",
      "sudo mv /home/${var.ssh_user}/config.yaml /etc/headscale/config.yaml",
      "sudo chown root:root /etc/headscale/config.yaml",
      "sudo chmod 644 /etc/headscale/config.yaml"
    ]
  }

  provisioner "file" {
    content     = templatefile("${path.root}/../data/headscale.service.tpl", {})
    destination = "/home/${var.ssh_user}/headscale.service"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/${var.ssh_user}/headscale.service /etc/systemd/system/headscale.service",
      "sudo chown root:root /etc/systemd/system/headscale.service",
      "sudo chmod 644 /etc/systemd/system/headscale.service",
      "sudo systemctl daemon-reload",
      "sudo systemctl restart headscale"
    ]
  }

  provisioner "file" {
    content     = templatefile("${path.root}/../data/journald.conf.tpl", {})
    destination = "/home/${var.ssh_user}/journald.conf"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/${var.ssh_user}/journald.conf /etc/systemd/journald.conf",
      "sudo chown root:root /etc/systemd/journald.conf",
      "sudo chmod 644 /etc/systemd/journald.conf",
      "sudo systemctl restart systemd-journald"
    ]
  }
}
