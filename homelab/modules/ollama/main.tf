resource "aws_security_group" "ollama" {
  name        = "headscale-ollama"
  description = "Allow inbound SSH only - Ollama accessed via tailnet"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Tailscale WireGuard UDP
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

resource "aws_instance" "ollama" {
  ami                    = var.ami
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.ollama.id]
  subnet_id              = var.subnet_id

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = <<-EOF
    #!/bin/bash
    mkdir -p /home/${var.ec2_user}/.ssh
    echo "${var.ssh_pub_key}" >> /home/${var.ec2_user}/.ssh/authorized_keys
    chown -R ${var.ec2_user}:${var.ec2_user} /home/${var.ec2_user}/.ssh
    chmod 600 /home/${var.ec2_user}/.ssh/authorized_keys
    sudo timedatectl set-ntp 1
    sudo timedatectl set-timezone America/Chicago
  EOF

  tags = {
    Name = "headscale-ollama"
  }
}

resource "aws_eip" "ollama" {
  instance = aws_instance.ollama.id
  domain   = "vpc"
  tags = {
    Name = "headscale-ollama"
  }
}

# --- Provisioning ---

resource "null_resource" "set_hostname" {
  connection {
    type        = "ssh"
    host        = aws_eip.ollama.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "2m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo hostnamectl set-hostname ollama"
    ]
  }
  depends_on = [aws_instance.ollama]
}

resource "null_resource" "install_nvidia_drivers" {
  count = var.skip_nvidia_install ? 0 : 1
  connection {
    type        = "ssh"
    host        = aws_eip.ollama.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "10m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo DEBIAN_FRONTEND=noninteractive apt-get update",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y linux-headers-$(uname -r) build-essential",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-driver-535 nvidia-utils-535",
    ]
  }
  depends_on = [null_resource.set_hostname]
}

resource "null_resource" "reboot_for_nvidia" {
  count = var.skip_nvidia_install ? 0 : 1
  connection {
    type        = "ssh"
    host        = aws_eip.ollama.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "2m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo reboot || true"
    ]
  }
  depends_on = [null_resource.install_nvidia_drivers]
}

resource "null_resource" "wait_for_reboot" {
  count = var.skip_nvidia_install ? 0 : 1
  provisioner "local-exec" {
    command = "sleep 60"
  }
  depends_on = [null_resource.reboot_for_nvidia]
}

resource "null_resource" "install_tailscale" {
  connection {
    type        = "ssh"
    host        = aws_eip.ollama.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "5m"
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
  depends_on = [
    null_resource.wait_for_reboot,
    null_resource.set_hostname
  ]
}

resource "null_resource" "upload_auth_key" {
  connection {
    type        = "ssh"
    host        = aws_eip.ollama.public_ip
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
    host        = aws_eip.ollama.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo tailscale up --login-server https://${var.headscale_server_domain} --auth-key file:///home/${var.ssh_user}/tailnet_auth_key --hostname ollama --accept-routes --reset --force-reauth && sudo rm /home/${var.ssh_user}/tailnet_auth_key"
    ]
  }
  depends_on = [null_resource.upload_auth_key]
}

resource "null_resource" "install_ollama" {
  connection {
    type        = "ssh"
    host        = aws_eip.ollama.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "5m"
  }
  provisioner "remote-exec" {
    inline = [
      "curl -fsSL https://ollama.com/install.sh | sh",
    ]
  }
  depends_on = [null_resource.tailnet_auth]
}

resource "null_resource" "configure_ollama" {
  connection {
    type        = "ssh"
    host        = aws_eip.ollama.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "2m"
  }

  provisioner "remote-exec" {
    inline = [
      "TS_IP=$(tailscale ip -4)",
      "echo \"Binding Ollama to tailscale IP: $TS_IP\"",
      "sudo mkdir -p /etc/systemd/system/ollama.service.d",
      "printf '[Service]\\nEnvironment=\"OLLAMA_HOST=%s:11434\"\\nEnvironment=\"OLLAMA_CONTEXT_LENGTH=${var.ollama_context_length}\"\\nEnvironment=\"OLLAMA_KV_CACHE_TYPE=${var.ollama_kv_cache_type}\"\\nEnvironment=\"OLLAMA_KEEP_ALIVE=${var.ollama_keep_alive}\"\\n' \"$TS_IP\" | sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable ollama",
      "sudo systemctl restart ollama",
      "sleep 5",
    ]
  }
  depends_on = [null_resource.install_ollama]
}

resource "null_resource" "pull_model" {
  count = var.default_model != "" ? 1 : 0
  connection {
    type        = "ssh"
    host        = aws_eip.ollama.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "30m"
  }
  provisioner "remote-exec" {
    inline = [
      "sleep 5",
      "OLLAMA_HOST=$(tailscale ip -4):11434 /usr/local/bin/ollama pull ${var.default_model}"
    ]
  }
  depends_on = [null_resource.configure_ollama]
}

resource "null_resource" "create_custom_model" {
  count = var.default_model != "" ? 1 : 0
  connection {
    type        = "ssh"
    host        = aws_eip.ollama.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "5m"
  }
  provisioner "remote-exec" {
    inline = [
      "cat > /tmp/Modelfile <<'MF'",
      "FROM ${var.default_model}",
      "PARAMETER num_ctx ${var.ollama_context_length}",
      "MF",
      "OLLAMA_HOST=$(tailscale ip -4):11434 ollama create ${replace(var.default_model, ":", "-")}-ctx -f /tmp/Modelfile",
      "rm /tmp/Modelfile"
    ]
  }
  depends_on = [null_resource.pull_model]
}

resource "null_resource" "pull_efficient_model" {
  count = var.efficient_model != "" ? 1 : 0
  connection {
    type        = "ssh"
    host        = aws_eip.ollama.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "30m"
  }
  provisioner "remote-exec" {
    inline = [
      "OLLAMA_HOST=$(tailscale ip -4):11434 /usr/local/bin/ollama pull ${var.efficient_model}"
    ]
  }
  depends_on = [null_resource.configure_ollama]
}

resource "null_resource" "create_efficient_custom_model" {
  count = var.efficient_model != "" ? 1 : 0
  connection {
    type        = "ssh"
    host        = aws_eip.ollama.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "5m"
  }
  provisioner "remote-exec" {
    inline = [
      "cat > /tmp/Modelfile <<'MF'",
      "FROM ${var.efficient_model}",
      "PARAMETER num_ctx 16384",
      "MF",
      "OLLAMA_HOST=$(tailscale ip -4):11434 ollama create ${replace(var.efficient_model, ":", "-")}-16k -f /tmp/Modelfile",
      "rm /tmp/Modelfile"
    ]
  }
  depends_on = [null_resource.pull_efficient_model]
}

resource "null_resource" "warmup_model" {
  count = var.default_model != "" ? 1 : 0
  connection {
    type        = "ssh"
    host        = aws_eip.ollama.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "10m"
  }
  provisioner "remote-exec" {
    inline = [
      "echo 'hello' | OLLAMA_HOST=$(tailscale ip -4):11434 ollama run ${replace(var.default_model, ":", "-")}-ctx --keepalive ${var.ollama_keep_alive} '' > /dev/null 2>&1 || true"
    ]
  }
  depends_on = [
    null_resource.create_custom_model,
    null_resource.create_efficient_custom_model
  ]
}
