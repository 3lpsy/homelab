

resource "null_resource" "install_deps" {
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  # Set permissions and optionally run a command
  provisioner "remote-exec" {
    inline = [
      "sudo dnf install -y git nginx neovim wget yq"
    ]
  }
}


resource "null_resource" "install_nomad_podman" {
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  # Set permissions and optionally run a command
  provisioner "remote-exec" {
    inline = [
      "sudo dnf install -y dnf-plugins-core",
      "sudo dnf config-manager addrepo --from-repofile=https://rpm.releases.hashicorp.com/fedora/hashicorp.repo",
      "sudo dnf install -y nomad containernetworking-plugins dmidecode nomad-driver-podman",
      "sudo dnf install -y podman podman-docker runc",
      "sudo systemctl enable nomad"
    ]
  }
  depends_on = [null_resource.install_deps]
}

resource "null_resource" "create_host_volume" {
  count = length(var.host_volumes)
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p ${var.host_volumes_dir}/${var.host_volumes[count.index]}",
      "sudo chown root:root ${var.host_volumes_dir}/${var.host_volumes[count.index]}",
      "sudo chmod 770 ${var.host_volumes_dir}/${var.host_volumes[count.index]}"
    ]
  }
}

resource "null_resource" "configure_nomad" {
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  triggers = {
    nomad_config    = md5(file("${path.root}/../data/nomad/nomad.hcl.tpl"))
    nomad_host_name = md5(var.nomad_host_name)
    host_volumes    = md5(join("-", var.host_volumes))
  }
  # Copy the fullchain.pem to the remote server
  provisioner "file" {
    content = templatefile("${path.root}/../data/nomad/nomad.hcl.tpl", {
      nomad_host_name = var.nomad_host_name
      host_volumes    = var.host_volumes
      }
    )
    destination = "/home/${var.ssh_user}/nomad.hcl"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/${var.ssh_user}/nomad.hcl /etc/nomad.d/nomad.hcl",
      "sudo chown -R nomad:nomad /etc/nomad.d/",
      "sudo chmod -R 644 /etc/nomad.d/",
      "sudo mkdir -p /opt/nomad/plugins",
      "sudo ln -s /usr/bin/nomad-driver-podman /opt/nomad/plugins/",
      "sudo systemctl restart nomad",
    ]
  }
  depends_on = [null_resource.install_nomad_podman, null_resource.create_host_volume]
}

resource "null_resource" "configure_podman" {
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  triggers = {
    config = md5(file("${path.root}/../data/podman/containers.conf.tpl"))
  }


  provisioner "file" {
    content     = file("${path.root}/../data/podman/containers.conf.tpl")
    destination = "/home/${var.ssh_user}/containers.conf"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/${var.ssh_user}/containers.conf /etc/containers/containers.conf",
      "sudo chown root:root /etc/containers/containers.conf",
      "sudo chmod 644 /etc/containers/containers.conf",
      "sudo systemctl enable --now podman.socket podman.service"
    ]
  }
  depends_on = [null_resource.install_deps]
}
