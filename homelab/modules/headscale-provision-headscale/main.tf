

resource "null_resource" "headscale_config" {
  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = trimspace(file(var.ssh_priv_key_path))
    timeout     = "1m"
  }
  triggers = {
    config = md5(templatefile("${path.root}/../data/headscale/config.yaml.tpl", {
      server_domain = var.headscale_server_domain
      server_port   = var.headscale_port
      magic_domain  = var.headscale_magic_domain
    }))
  }

  provisioner "file" {
    content = templatefile("${path.root}/../data/headscale/config.yaml.tpl", {
      server_domain = var.headscale_server_domain
      server_port   = var.headscale_port
      magic_domain  = var.headscale_magic_domain
    })
    destination = "/home/${var.ssh_user}/config.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p /etc/headscale",
      "sudo mv /home/${var.ssh_user}/config.yaml /etc/headscale/config.yaml",
      "sudo chown root:root /etc/headscale/config.yaml",
      "sudo chmod 644 /etc/headscale/config.yaml",
    ]
  }
}


resource "null_resource" "headscale_service" {
  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = trimspace(file(var.ssh_priv_key_path))
    timeout     = "1m"
  }

  provisioner "file" {
    content     = templatefile("${path.root}/../data/headscale/headscale.service.tpl", {})
    destination = "/home/${var.ssh_user}/headscale.service"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/${var.ssh_user}/headscale.service /etc/systemd/system/headscale.service",
      "sudo chown root:root /etc/systemd/system/headscale.service",
      "sudo chmod 644 /etc/systemd/system/headscale.service",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable headscale"

    ]
  }
  depends_on = [null_resource.headscale_config]
}

resource "null_resource" "headscale_restart" {
  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = trimspace(file(var.ssh_priv_key_path))
    timeout     = "1m"
  }
  triggers = {
    config = md5(templatefile("${path.root}/../data/headscale/config.yaml.tpl", {
      server_domain = var.headscale_server_domain
      server_port   = var.headscale_port
      magic_domain  = var.headscale_magic_domain
    }))
  }

  provisioner "remote-exec" {
    inline = [
      "sudo systemctl restart headscale"
    ]
  }
  depends_on = [null_resource.headscale_config, null_resource.headscale_service]
}



resource "null_resource" "journald" {
  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = trimspace(file(var.ssh_priv_key_path))
    timeout     = "1m"
  }

  provisioner "file" {
    content     = templatefile("${path.root}/../data/server/journald.conf.tpl", {})
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


# Legacy age-encrypted SQLite backup (tls_private_key.encryption_key,
# null_resource.encryption_key/backup_script/backup_cron) was removed in
# favour of a generic kopia client wired up in homelab/main.tf via
# module.headscale-provision-kopia. The kopia client covers /etc,
# /var/lib/headscale, and /root and ships daily snapshots to S3.

resource "null_resource" "create_api_key" {
  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = trimspace(file(var.ssh_priv_key_path))
    timeout     = "1m"
  }

  provisioner "remote-exec" {
    inline = [
      "/usr/local/bin/headscale apikey create | tr -d '\"' > /tmp/headscale.key"
    ]
  }
  depends_on = [null_resource.headscale_service]
}

resource "null_resource" "download_api_key" {
  provisioner "local-exec" {
    command     = <<-EOT
      scp -i "${var.ssh_priv_key_path}" -o StrictHostKeyChecking=no "${var.ssh_user}@${var.server_ip}:/tmp/headscale.key" "${var.headscale_key_path}"
    EOT
    interpreter = ["/bin/bash", "-c"]
  }
  depends_on = [null_resource.create_api_key]
}

data "local_file" "api_key" {
  filename   = var.headscale_key_path
  depends_on = [null_resource.create_api_key, null_resource.download_api_key]
}

resource "null_resource" "delete_api_key_remote" {
  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = trimspace(file(var.ssh_priv_key_path))
    timeout     = "1m"
  }

  provisioner "remote-exec" {
    inline = [
      "rm /tmp/headscale.key"
    ]
  }
  depends_on = [null_resource.headscale_service]
}
