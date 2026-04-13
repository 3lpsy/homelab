resource "random_password" "litellm_master_key" {
  length  = 32
  special = false
}

resource "aws_security_group" "litellm" {
  name        = "headscale-litellm"
  description = "SSH + Tailscale only - LiteLLM accessed via tailnet"
  vpc_id      = var.vpc_id
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

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

resource "aws_iam_role" "litellm" {
  name = "homelab-litellm-bedrock"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "litellm_bedrock" {
  name = "homelab-litellm-bedrock"
  role = aws_iam_role.litellm.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ]
      Resource = [
        "arn:aws:bedrock:*::foundation-model/*",
        "arn:aws:bedrock:*:*:inference-profile/*"
      ]
      },
      {
        Effect = "Allow"
        Action = [
          "aws-marketplace:ViewSubscriptions",
          "aws-marketplace:Subscribe"
        ]
        Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "litellm" {
  name = aws_iam_role.litellm.name
  role = aws_iam_role.litellm.name
}

resource "aws_instance" "litellm" {
  ami                         = var.ami
  instance_type               = var.instance_type
  vpc_security_group_ids      = [aws_security_group.litellm.id]
  subnet_id                   = var.subnet_id
  iam_instance_profile        = aws_iam_instance_profile.litellm.name
  associate_public_ip_address = true
  root_block_device {
    volume_size = 10
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
    Name = "headscale-litellm"
  }
}


resource "null_resource" "set_hostname" {
  connection {
    type        = "ssh"
    host        = aws_instance.litellm.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "2m"
  }
  provisioner "remote-exec" {
    inline = ["sudo hostnamectl set-hostname litellm"]
  }
  depends_on = [aws_instance.litellm]
  triggers = {
    instance_id = aws_instance.litellm.id
  }
}

# --- Provisioning: tailscale ---

resource "null_resource" "install_tailscale" {
  connection {
    type        = "ssh"
    host        = aws_instance.litellm.public_ip
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
  depends_on = [null_resource.set_hostname]
  triggers = {
    instance_id = aws_instance.litellm.id
  }
}

resource "null_resource" "upload_auth_key" {
  connection {
    type        = "ssh"
    host        = aws_instance.litellm.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "file" {
    content     = var.tailnet_auth_key
    destination = "/home/${var.ssh_user}/tailnet_auth_key"
  }
  depends_on = [null_resource.install_tailscale]
  triggers = {
    instance_id = aws_instance.litellm.id
  }
}

resource "null_resource" "tailnet_auth" {
  connection {
    type        = "ssh"
    host        = aws_instance.litellm.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo tailscale up --login-server https://${var.headscale_server_domain} --auth-key file:///home/${var.ssh_user}/tailnet_auth_key --hostname litellm --accept-routes --reset --force-reauth && sudo rm /home/${var.ssh_user}/tailnet_auth_key"
    ]
  }
  depends_on = [null_resource.upload_auth_key]
  triggers = {
    instance_id = aws_instance.litellm.id
  }
}


resource "null_resource" "install_litellm" {
  connection {
    type        = "ssh"
    host        = aws_instance.litellm.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "10m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y python3-pip python3-venv",
      "sudo python3 -m venv /opt/litellm",
      "sudo /opt/litellm/bin/pip install 'litellm[proxy]' prisma litellm-proxy-extras",
      "SCHEMA=$(find /opt/litellm -name 'schema.prisma' -path '*/litellm/proxy/*' | head -1) && sudo PATH=/opt/litellm/bin:$PATH /opt/litellm/bin/prisma generate --schema $SCHEMA"
    ]
  }
  depends_on = [null_resource.tailnet_auth]
  triggers = {
    instance_id = aws_instance.litellm.id
  }
}

resource "random_password" "litellm_db" {
  length  = 24
  special = false
}

resource "null_resource" "install_postgres" {
  connection {
    type        = "ssh"
    host        = aws_instance.litellm.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "5m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y postgresql postgresql-contrib",
      "sudo systemctl enable --now postgresql",
      "sleep 4",
      "sudo -u postgres psql -c \"CREATE USER litellm WITH PASSWORD '${random_password.litellm_db.result}';\"",
      "sudo -u postgres psql -c \"CREATE DATABASE litellm OWNER litellm;\"",
      "SCHEMA=$(find /opt/litellm -name 'schema.prisma' -path '*/litellm_proxy_extras/*' | head -1) && sudo DATABASE_URL='postgresql://litellm:${random_password.litellm_db.result}@127.0.0.1:5432/litellm' PATH=/opt/litellm/bin:$PATH /opt/litellm/bin/prisma migrate deploy --schema $SCHEMA"
    ]
  }
  depends_on = [null_resource.install_litellm]
}


resource "null_resource" "litellm_config" {
  connection {
    type        = "ssh"
    host        = aws_instance.litellm.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }

  triggers = {
    config      = md5(local.litellm_config_yaml)
    instance_id = aws_instance.litellm.id
  }

  provisioner "file" {
    content     = local.litellm_config_yaml
    destination = "/home/${var.ssh_user}/litellm_config.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p /etc/litellm",
      "sudo mv /home/${var.ssh_user}/litellm_config.yaml /etc/litellm/config.yaml",
      "sudo chown root:root /etc/litellm/config.yaml",
      "sudo chmod 600 /etc/litellm/config.yaml",
    ]
  }
  depends_on = [null_resource.install_litellm, null_resource.install_postgres]
}

resource "null_resource" "litellm_service" {
  connection {
    type        = "ssh"
    host        = aws_instance.litellm.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }

  provisioner "file" {
    content     = local.litellm_service_unit
    destination = "/home/${var.ssh_user}/litellm.service"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/${var.ssh_user}/litellm.service /etc/systemd/system/litellm.service",
      "sudo chown root:root /etc/systemd/system/litellm.service",
      "sudo chmod 644 /etc/systemd/system/litellm.service",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable litellm",
    ]
  }
  depends_on = [null_resource.litellm_config]
  triggers = {
    instance_id = aws_instance.litellm.id
  }
}

resource "null_resource" "litellm_start" {
  connection {
    type        = "ssh"
    host        = aws_instance.litellm.public_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }

  triggers = {
    config      = md5(local.litellm_config_yaml)
    instance_id = aws_instance.litellm.id
  }

  provisioner "remote-exec" {
    inline = [
      "sudo systemctl restart litellm",
      "sleep 3",
      "sudo systemctl is-active litellm"
    ]
  }
  depends_on = [null_resource.litellm_service, null_resource.litellm_config]
}

# --- Locals ---

locals {
  bedrock_models_list = [
    for alias, cfg in var.bedrock_models : {
      model_name    = alias
      litellm_model = "bedrock/${cfg.model_id}"
      max_tokens    = cfg.max_tokens
    }
  ]

  ollama_default_models = [
    {
      model_name    = "qwen3.5:27b"
      litellm_model = "ollama/qwen3.5:27b"
      max_tokens    = null
    },
    {
      model_name    = "qwen3.5:35b-a3b"
      litellm_model = "ollama/qwen3.5:35b-a3b"
      max_tokens    = null
    }
  ]

  extra_litellm_models = [
    for m in var.litellm_models : {
      model_name    = m.model_name
      litellm_model = m.litellm_model
      max_tokens    = null
    }
  ]

  all_models = concat(local.bedrock_models_list, local.ollama_default_models, local.extra_litellm_models)

  litellm_config_yaml = yamlencode({
    model_list = [
      for m in local.all_models : {
        model_name = m.model_name
        litellm_params = { for k, v in {
          model           = m.litellm_model
          api_base        = startswith(m.litellm_model, "ollama/") ? "http://${var.ollama_tailnet_host}:${var.ollama_port}" : null
          aws_region_name = startswith(m.litellm_model, "bedrock/") ? var.aws_region : null
          max_tokens      = m.max_tokens
          cache_control_injection_points = startswith(m.litellm_model, "bedrock/") ? [
            { location = "message", role = "system" },
            { location = "message", index = -2 },
            { location = "message", index = -1 },
          ] : null
        } : k => v if v != null }
      }
    ]
    litellm_settings = {
      default_internal_user_params = {
        max_budget = var.default_user_max_budget
      }
    }
    general_settings = {
      master_key   = "sk-${random_password.litellm_master_key.result}"
      database_url = "postgresql://litellm:${random_password.litellm_db.result}@127.0.0.1:5432/litellm"
    }
  })

  litellm_service_unit = <<-UNIT
    [Unit]
    Description=LiteLLM Proxy
    After=network-online.target tailscaled.service
    Wants=network-online.target

    [Service]
    Type=simple
    ExecStartPre=/bin/bash -c 'until tailscale ip -4 2>/dev/null; do sleep 1; done'
    ExecStart=/bin/bash -c '/opt/litellm/bin/litellm --config /etc/litellm/config.yaml --host $$(tailscale ip -4) --port ${var.litellm_port}'
    Restart=on-failure
    RestartSec=5
    Environment="AWS_DEFAULT_REGION=${var.aws_region}"
    Environment="PATH=/opt/litellm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    [Install]
    WantedBy=multi-user.target
  UNIT
}
