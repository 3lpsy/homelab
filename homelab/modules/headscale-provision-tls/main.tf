
resource "null_resource" "install_certs" {
  # Triggers to ensure the resource runs when the certificates change
  triggers = {
    fullchain_pem = md5(var.tls_fullchain_pem)
    privkey_pem   = md5(var.tls_privkey_pem)
  }

  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }

  # Copy the fullchain.pem to the remote server
  provisioner "file" {
    content     = var.tls_fullchain_pem
    destination = "/home/${var.ssh_user}/fullchain.pem"
  }

  # Copy the privkey.pem to the remote server
  provisioner "file" {
    content     = var.tls_privkey_pem
    destination = "/home/${var.ssh_user}/privkey.pem"
  }

  # Set permissions and optionally run a command
  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/${var.ssh_user}/privkey.pem /etc/letsencrypt/live/${var.domain}/privkey.pem",
      "sudo mv /home/${var.ssh_user}/fullchain.pem /etc/letsencrypt/live/${var.domain}/fullchain.pem",
      "sudo groupadd ssl-cert || echo true >/dev/null",
      "sudo chown root:ssl-cert /etc/letsencrypt/live/${var.domain}/privkey.pem",
      "sudo chown root:ssl-cert /etc/letsencrypt/live/${var.domain}/fullchain.pem",
      "sudo chmod 640 '/etc/letsencrypt/live/${var.domain}/privkey.pem'",
      "sudo chmod 644 '/etc/letsencrypt/live/${var.domain}/fullchain.pem'",
      "sudo systemctl restart nginx"
    ]
  }
}
