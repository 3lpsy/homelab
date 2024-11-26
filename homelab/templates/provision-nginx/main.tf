
resource "null_resource" "main" {
  triggers = {
    config = md5(templatefile("${path.root}/../data/nginx/nginx.conf.tpl", {
      server_domain = var.server_domain
      proxy_port    = var.proxy_port
      proxy_proto   = var.proxy_proto
      nginx_user    = var.nginx_user
    }))
  }
  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }

  provisioner "file" {
    content = templatefile("${path.root}/../data/nginx/nginx.conf.tpl", {
      server_domain = var.server_domain
      proxy_port    = var.proxy_port
      proxy_proto   = var.proxy_proto
      nginx_user    = var.nginx_user
    })
    destination = "/home/${var.ssh_user}/nginx.conf"
  }

  # Set permissions and optionally run a command
  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/${var.ssh_user}/nginx.conf /etc/nginx/nginx.conf",
      "sudo chown root:${var.nginx_user} /etc/nginx/nginx.conf",
      "sudo chmod 644 /etc/nginx/nginx.conf",
      "sudo mkdir -p /var/log/nginx/",
      "sudo chown nginx:nginx /var/log/nginx",
      "sudo restorecon -Rv /etc/nginx 2>/dev/null || echo 'SELinux Not Installed. Ignoring Restore.'",
      "sudo setsebool -P httpd_can_network_connect on || echo 'SELinux Not Installed. Ignoring Restore.'",
      "sudo systemctl enable nginx",
      "sudo systemctl stop nginx",
      "sudo systemctl restart nginx"
    ]
  }
}
