resource "null_resource" "install_containerd" {
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo dnf install -y containerd containernetworking-plugins",

    ]
  }
  depends_on = [null_resource.install_deps]
}


resource "null_resource" "install_nerdctl" {
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p /opt/nerdctl-src",
      "sudo chown ${var.ssh_user}:${var.ssh_user} /opt/nerdctl-src",
      "cd /opt/nerdctl-src",
      "sudo wget https://github.com/containerd/nerdctl/releases/download/v2.0.0/nerdctl-full-2.0.0-linux-amd64.tar.gz -O /opt/nerdctl-src/nerdctl-full-2.0.0-linux-amd64.tar.gz",
      "sudo tar xzvf nerdctl-full-2.0.0-linux-amd64.tar.gz",
      "sudo chown -R root:root /opt/nerdctl-src",
      "sudo mv /opt/nerdctl-src/bin/nerdctl /usr/local/bin/"
    ]
  }
  depends_on = [null_resource.install_buildkit]
}
resource "null_resource" "install_buildkit" {
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "cd /opt/nerdctl-src",
      "sudo mv /opt/nerdctl-src/bin/buildkit* /usr/local/bin/",
      "sudo mv /opt/nerdctl-src/bin/buildctl /usr/local/bin/",
      "sudo cp /opt/nerdctl-src/lib/systemd/system/buildkit.service /etc/systemd/system/buildkit.service",
      "sudo systemctl daemon-reload"

    ]
  }
  depends_on = [null_resource.install_containerd]
}

resource "null_resource" "configure_containerd" {
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  triggers = {
    config = md5(templatefile("${path.root}/../data/containerd/config.toml.tpl", {
      devmapper_base_image_size = 50
      devmapper_pool_name       = "containerd-pool"
      devmapper_root_path       = "/var/lib/containerd/devmapper"
      cni_bin_dir               = "/usr/libexec/cni"
    }))
  }
  # Copy the fullchain.pem to the remote server
  provisioner "file" {
    content = templatefile("${path.root}/../data/containerd/config.toml.tpl", {
      devmapper_base_image_size = 50
      devmapper_pool_name       = "containerd-pool"
      devmapper_root_path       = "/var/lib/containerd/devmapper"
      cni_bin_dir               = "/usr/libexec/cni"
    })
    destination = "/home/${var.ssh_user}/config.toml"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/${var.ssh_user}/config.toml /etc/containerd/config.toml",
      "sudo chown -R root:root /etc/containerd/config.toml",
      "sudo chmod -R 644 /etc/containerd/config.toml"
    ]
  }
  depends_on = [null_resource.install_firecracker]
}

resource "null_resource" "configure_buildkit" {
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  triggers = {
    config = md5(file("${path.root}/../data/buildkit/buildkitd.toml.tpl"))
  }
  # Copy the fullchain.pem to the remote server
  provisioner "file" {
    content     = file("${path.root}/../data/buildkit/buildkitd.toml.tpl")
    destination = "/home/${var.ssh_user}/buildkitd.toml"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo mkdir /etc/buildkit/",
      "sudo mv /home/${var.ssh_user}/buildkitd.toml /etc/buildkit/buildkitd.toml",
      "sudo chown -R root:root /etc/buildkit/buildkitd.toml",
      "sudo chmod -R 644 /etc/buildkit/buildkitd.toml"
    ]
  }
  depends_on = [null_resource.configure_containerd]
}

resource "null_resource" "configure_containerd_devmapper" {
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  triggers = {
    create_sparse = md5(templatefile("${path.root}/../data/containerd/create-devmapper-sparse.sh.tpl", {
      devmapper_base_image_size = 50
      devmapper_pool_name       = "containerd-pool"
      devmapper_root_path       = "/var/lib/containerd/devmapper"
    }))
  }
  provisioner "file" {
    content = templatefile("${path.root}/../data/containerd/create-devmapper-sparse.sh.tpl", {
      devmapper_base_image_size = 50
      devmapper_pool_name       = "containerd-pool"
      devmapper_root_path       = "/var/lib/containerd/devmapper"
    })
    destination = "/home/${var.ssh_user}/create-devmapper-sparse.sh"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/${var.ssh_user}/create-devmapper-sparse.sh /usr/local/bin/create-devmapper-sparse.sh",
      "sudo chown root:root /usr/local/bin/create-devmapper-sparse.sh",
      "sudo chmod +x /usr/local/bin/create-devmapper-sparse.sh",
      "sudo bash /usr/local/bin/create-devmapper-sparse.sh"
    ]
  }
  depends_on = [null_resource.configure_containerd]
}

resource "null_resource" "start_containerd" {
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo systemctl enable containerd",
      "sudo systemctl restart containerd",
      "sudo systemctl enable buildkit",
      "sudo systemctl restart buildkit",
      "sudo systemctl enable --now buildkit.socket",

    ]
  }
  depends_on = [null_resource.configure_containerd_devmapper]
}

resource "null_resource" "containerd_thinpool_loader" {
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  triggers = {
    script = md5(templatefile("${path.root}/../data/containerd/reload-devmapper-thinpool.sh.tpl", {
      devmapper_pool_name = "containerd-pool"
      devmapper_root_path = "/var/lib/containerd/devmapper"
    }))
  }
  provisioner "file" {
    content = templatefile("${path.root}/../data/containerd/reload-devmapper-thinpool.sh.tpl", {
      devmapper_pool_name = "containerd-pool"
      devmapper_root_path = "/var/lib/containerd/devmapper"
    })
    destination = "/home/${var.ssh_user}/reload-devmapper-thinpool.sh"
  }
  provisioner "file" {
    content     = file("${path.root}/../data/containerd/reload-devmapper-thinpool.service.tpl")
    destination = "/home/${var.ssh_user}/reload-devmapper-thinpool.service"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/${var.ssh_user}/reload-devmapper-thinpool.sh /usr/local/bin/reload-devmapper-thinpool.sh",
      "sudo chown root:root /usr/local/bin/reload-devmapper-thinpool.sh",
      "sudo chmod +x /usr/local/bin/reload-devmapper-thinpool.sh",
      "sudo mv /home/${var.ssh_user}/reload-devmapper-thinpool.service /etc/systemd/system/reload-devmapper-thinpool.service",
      "sudo chown root:root /etc/systemd/system/reload-devmapper-thinpool.service",
      "sudo restorecon -v /etc/systemd/system/reload-devmapper-thinpool.service || echo 'No SELinux'",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable --now reload-devmapper-thinpool"
    ]
  }
  depends_on = [null_resource.configure_containerd_devmapper]
}
