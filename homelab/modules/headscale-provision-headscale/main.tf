

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
    acls = md5(templatefile("${path.root}/../data/headscale/acls.hjson.tpl", {
      personal_user         = var.personal_username
      nomad_server_user     = var.nomad_server_username
      mobile_user           = var.mobile_username
      tablet_user           = var.tablet_username
      deck_user             = var.deck_username
      devbox_user           = var.devbox_username
      vault_server_user     = var.vault_server_username
      nextcloud_server_user = var.nextcloud_server_username

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

  provisioner "file" {
    content = templatefile("${path.root}/../data/headscale/acls.hjson.tpl", {
      personal_user         = var.personal_username
      nomad_server_user     = var.nomad_server_username
      mobile_user           = var.mobile_username
      tablet_user           = var.tablet_username
      deck_user             = var.deck_username
      devbox_user           = var.devbox_username
      vault_server_user     = var.vault_server_username
      nextcloud_server_user = var.nextcloud_server_username

    })
    destination = "/home/${var.ssh_user}/acls.hjson"
  }

  # Set permissions and optionally run a command
  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/${var.ssh_user}/acls.hjson /etc/headscale/acls.hjson",
      "sudo chown root:headscale /etc/headscale/acls.hjson",
      "sudo chmod 644 /etc/headscale/acls.hjson",
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
    acls = md5(templatefile("${path.root}/../data/headscale/acls.hjson.tpl", {
      personal_user         = var.personal_username
      nomad_server_user     = var.nomad_server_username
      mobile_user           = var.mobile_username
      tablet_user           = var.tablet_username
      deck_user             = var.deck_username
      devbox_user           = var.devbox_username
      vault_server_user     = var.vault_server_username
      nextcloud_server_user = var.nextcloud_server_username

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


# ED25519 key
resource "tls_private_key" "encryption_key" {
  algorithm = "ED25519"
}

resource "null_resource" "encryption_key" {
  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = trimspace(file(var.ssh_priv_key_path))
    timeout     = "1m"
  }

  provisioner "file" {
    content     = tls_private_key.encryption_key.public_key_openssh
    destination = "/home/${var.ssh_user}/encryption_key.pub"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/${var.ssh_user}/encryption_key.pub /etc/headscale/encryption_key.pub",
      "sudo chown root:headscale /etc/headscale/encryption_key.pub"
    ]
  }
}

resource "null_resource" "backup_script" {
  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = trimspace(file(var.ssh_priv_key_path))
    timeout     = "1m"
  }

  provisioner "file" {
    content = templatefile("${path.root}/../data/headscale/backup-headscale.sh.tpl", {
      ssh_pub_key_path   = "/etc/headscale/encryption_key.pub",
      backup_bucket_name = var.backup_bucket_name
    })
    destination = "/home/${var.ssh_user}/backup-headscale.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/${var.ssh_user}/backup-headscale.sh /usr/local/bin/backup-headscale.sh",
      "sudo chown root:headscale /usr/local/bin/backup-headscale.sh",
      "sudo chmod 644 /usr/local/bin/backup-headscale.sh",
      "sudo chmod g+x /usr/local/bin/backup-headscale.sh"
    ]
  }
  depends_on = [null_resource.encryption_key]
}

resource "null_resource" "backup_cron" {
  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = trimspace(file(var.ssh_priv_key_path))
    timeout     = "1m"
  }

  provisioner "file" {
    content     = file("${path.root}/../data/headscale/backup-headscale-cron.tpl")
    destination = "/home/${var.ssh_user}/backup-headscale-cron"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/${var.ssh_user}/backup-headscale-cron /etc/cron.d/backup-headscale-cron",
      "sudo chown root:root /etc/cron.d/backup-headscale-cron",
      "sudo chmod 644 /etc/cron.d/backup-headscale-cron",
      "sudo touch /var/log/backup-headscale.log",
      "sudo chown headscale:headscale /var/log/backup-headscale.log"
    ]
  }
  depends_on = [null_resource.backup_script]
}

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
  depends_on = [null_resource.backup_script]
}

resource "null_resource" "download_api_key" {
  provisioner "local-exec" {
    command     = <<-EOT
      scp -i "${var.ssh_priv_key_path}" -o StrictHostKeyChecking=no "${var.ssh_user}@${var.server_ip}:/tmp/headscale.key" "${path.root}/../headscale.key"
    EOT
    interpreter = ["/bin/bash", "-c"]
  }
  depends_on = [null_resource.create_api_key]
}

data "local_file" "api_key" {
  filename   = "${path.root}/../headscale.key"
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
  depends_on = [null_resource.backup_script]
}
