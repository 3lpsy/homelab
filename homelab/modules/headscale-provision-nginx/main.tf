

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
    content = templatefile("${path.root}/../data/nginx.conf.tpl", {
      server_domain = var.headscale_domain
      proxy_port    = var.headscale_port
    })
    destination = "/home/${var.ssh_user}/nginx.conf"
  }

  # Set permissions and optionally run a command
  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/${var.ssh_user}/nginx.conf /etc/nginx/nginx.conf",
      "sudo chown root:root /etc/nginx/nginx.conf",
      "sudo chmod 644 /etc/nginx/nginx.conf",
      "sudo systemctl stop nginx",
      "sudo systemctl restart nginx"
    ]
  }
}
