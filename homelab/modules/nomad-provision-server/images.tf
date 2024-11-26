

resource "null_resource" "upload_images" {
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  triggers = {
    arb = md5("x")
  }
  provisioner "file" {
    source      = "${path.root}/../data/images"
    destination = "/home/${var.ssh_user}/images"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/${var.ssh_user}/images /opt/images",
      "sudo chown root:root /opt/images"
    ]
  }
  depends_on = [null_resource.configure_kata]
}
