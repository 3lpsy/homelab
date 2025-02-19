
resource "null_resource" "main" {
  # Triggers to ensure the resource runs when the certificates change
  triggers = {
    fullchain_pem = md5(var.tls_fullchain_pem)
    privkey_pem   = md5(var.tls_privkey_pem)
    domain        = var.domain
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
      "sudo mkdir -p /etc/letsencrypt/live/${var.domain}",
      "sudo mkdir -p /etc/letsencrypt/archive/${var.domain}",
      "sudo mv /home/${var.ssh_user}/privkey.pem /etc/letsencrypt/live/${var.domain}/privkey.pem",
      "sudo mv /home/${var.ssh_user}/fullchain.pem /etc/letsencrypt/live/${var.domain}/fullchain.pem",
      "sudo groupadd ssl-cert || echo true >/dev/null",
      "sudo chown root:ssl-cert /etc/letsencrypt/live/${var.domain}/privkey.pem",
      "sudo chown root:ssl-cert /etc/letsencrypt/live/${var.domain}/fullchain.pem",
      "sudo chmod 640 '/etc/letsencrypt/live/${var.domain}/privkey.pem'",
      "sudo chmod 644 '/etc/letsencrypt/live/${var.domain}/fullchain.pem'",
      "sudo restorecon -Rv /etc/letsencrypt/live/${var.domain}/fullchain.pem 2>/dev/null || echo 'SELinux Not Installed. Ignoring Restore.'",
      "sudo restorecon -Rv /etc/letsencrypt/live/${var.domain}/privkey.pem 2>/dev/null || echo 'SELinux Not Installed. Ignoring Restore.'",
    ]
  }
}
