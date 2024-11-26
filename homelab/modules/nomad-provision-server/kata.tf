resource "null_resource" "install_kata" {
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  # Add kata to path
  provisioner "remote-exec" {
    inline = [
      "(echo 'export PATH=/opt/kata/bin:$PATH'; cat /etc/profile) > /tmp/profile.tmp",
      "sudo mv /tmp/profile.tmp /etc/profile",
      "sudo chown root:root /etc/profile",
      "sudo chmod 644 /etc/profile",
      "source /etc/profile"
    ]
  }
  # Unpack tarbell, comes with rootfs images but no osbuilder
  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p /opt/kata/src",
      "sudo chown -R ${var.ssh_user}:${var.ssh_user} /opt/kata",
      "wget https://github.com/kata-containers/kata-containers/releases/download/${var.kata_version}/kata-static-${var.kata_version}amd64.tar.xz -O /opt/kata/src/kata-static-${var.kata_version}amd64.tar.xz",
      "cd /opt/kata/src",
      "tar -xvf kata-static-${var.kata_version}-amd64.tar.xz",
      "sudo chown -R root:root /opt/kata",
      "sudo mv ./opt/kata/* /opt/kata",
      "sudo mv ./usr/bin/* /opt/kata/bin/",
      "sudo mv ./usr/local/bin/* /opt/kata/bin/",

    ]
  }
  # Not sure if we need these
  provisioner "remote-exec" {
    inline = [
      "cd /opt/kata/src",
      "sudo mv ./usr/lib/systemd/system/*.service /etc/systemd/system/",
      "sudo mv ./usr/lib/systemd/system/*.target /etc/systemd/system/"
    ]
  }
  # Some symlinks, second one for containerd (maybe optional)
  provisioner "remote-exec" {
    inline = [
      "sudo ln -s /opt/kata/bin/kata-runtime /usr/local/bin",
      "sudo ln -s /opt/kata/bin/containerd-shim-kata-v2 /usr/local/bin",
      "cd /tmp",
      "sudo rm -rf /opt/kata/src"
    ]
  }
  # so we can make rootfs images later if we want
  provisioner "remote-exec" {
    inline = [
      "cd /tmp",
      "sudo git clone --depth 1 -b ${var.kata_version} https://github.com/kata-containers/kata-containers.git /opt/kata-src"
    ]
  }
  depends_on = [null_resource.install_containerd]
}


resource "null_resource" "configure_kata" {
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  triggers = {
    config = md5(file("${path.root}/../data/kata/configuration.toml.tpl"))
  }


  provisioner "file" {
    content     = file("${path.root}/../data/kata/configuration.toml.tpl")
    destination = "/home/${var.ssh_user}/configuration.toml"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p /etc/kata-containers",
      "sudo mv /home/${var.ssh_user}/configuration.toml /etc/kata-containers/configuration.toml",
      "sudo chown -R root:root /etc/kata-containers",
      "sudo chmod 644 /etc/kata-containers/configuration.toml"
    ]
  }
  depends_on = [null_resource.start_containerd]
}
