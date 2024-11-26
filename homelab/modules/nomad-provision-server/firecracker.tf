
resource "null_resource" "install_firecracker" {
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo mkdir /opt/firecracker",
      "sudo chown ${var.ssh_user}:${var.ssh_user} /opt/firecracker",
      "wget https://github.com/firecracker-microvm/firecracker/releases/download/v${var.firecracker_version}/firecracker-v${var.firecracker_version}-x86_64.tgz -O /opt/firecracker/firecracker.tgz",
      "tar xzvf firecracker.tgz",
      "sudo mv /opt/firecracker/release-v${var.firecracker_version}-x86_64/firecracker-v${var.firecracker_version}-x86_64 /usr/local/bin/firecracker",
      "sudo mv /opt/firecracker/release-v${var.firecracker_version}-x86_64/jailer-v${var.firecracker_version}-x86_64 /usr/local/bin/jailer",
      "sudo chmod +x /usr/local/bin/jailer",
      "sudo chmod +x /usr/local/bin/firecracker"
    ]
  }
  depends_on = [null_resource.install_kata]
}
