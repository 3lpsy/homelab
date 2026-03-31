resource "aws_security_group" "exit_node" {
  name        = "headscale-exit-node-${var.node_name}"
  description = "Allow inbound traffic on ssh"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  # Derp / major perf difference
  ingress {
    from_port   = 41641
    to_port     = 41641
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}



resource "aws_instance" "exit_node" {
  ami                    = var.ami
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.exit_node.id]
  subnet_id              = aws_subnet.exit_node.id
  user_data              = <<-EOF
    #!/bin/bash
    mkdir -p /home/${var.ec2_user}/.ssh
    echo "${var.ssh_pub_key}" >> /home/${var.ec2_user}/.ssh/authorized_keys
    chown -R ${var.ec2_user}:${var.ec2_user} /home/${var.ec2_user}/.ssh
    chmod 600 /home/${var.ec2_user}/.ssh/authorized_keys
    sudo timedatectl set-ntp 1
    sudo timedatectl set-timezone America/Chicago
  EOF
  tags = {
    Name = "headscale-exit-node-${var.node_name}"
  }
}


resource "aws_eip" "exit_node" {
  instance = aws_instance.exit_node.id
  domain   = "vpc"
  tags = {
    Name = "headscale-exit-node-${var.node_name}"
  }
}


resource "null_resource" "set_hostname" {
  connection {
    type        = "ssh"
    host        = aws_eip.exit_node.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo hostnamectl set-hostname exitnode-${var.node_name}"
    ]
  }
  depends_on = [aws_instance.exit_node]
}

resource "null_resource" "install_tailscale" {
  connection {
    type        = "ssh"
    host        = aws_eip.exit_node.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null",
      "curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list | sudo tee /etc/apt/sources.list.d/tailscale.list",
      "sudo apt-get update",
      "sudo apt-get install tailscale -y",
      "sudo systemctl enable --now tailscaled"
    ]
  }
  depends_on = [aws_instance.exit_node, null_resource.set_hostname]
}

resource "null_resource" "upload_auth_key" {
  connection {
    type        = "ssh"
    host        = aws_eip.exit_node.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "file" {
    content     = var.tailnet_auth_key
    destination = "/home/${var.ssh_user}/tailnet_auth_key"
  }
  depends_on = [aws_instance.exit_node, null_resource.install_tailscale]
}
resource "null_resource" "enable_forwarding" {
  connection {
    type        = "ssh"
    host        = aws_eip.exit_node.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf",
      "echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf",
      "sudo sysctl -p /etc/sysctl.d/99-tailscale.conf"
    ]
  }
  depends_on = [aws_instance.exit_node, null_resource.upload_auth_key]
}
resource "null_resource" "tailnet_auth" {
  connection {
    type        = "ssh"
    host        = aws_eip.exit_node.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo tailscale up --login-server https://${var.headscale_server_domain} --auth-key file:///home/${var.ssh_user}/tailnet_auth_key --hostname exitnode-${var.node_name} --advertise-tags=tag:exitnode --accept-routes --advertise-exit-node --reset --force-reauth && sudo rm /home/${var.ssh_user}/tailnet_auth_key"
    ]
  }
  depends_on = [aws_instance.exit_node, null_resource.upload_auth_key, null_resource.enable_forwarding]
}
