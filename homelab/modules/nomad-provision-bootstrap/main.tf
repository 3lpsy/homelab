
resource "random_uuid" "nomad_acl_token" {}


resource "null_resource" "bootstrap_nomad" {
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "file" {
    content     = random_uuid.nomad_acl_token.result
    destination = "/home/${var.ssh_user}/root.token"
  }
  # Set permissions and optionally run a command
  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/${var.ssh_user}/root.token /etc/nomad.d/root.token",
      "sudo chown root:root /etc/nomad.d/root.token",
      "sudo chown 600 /etc/nomad.d/root.token",
      "sudo NOMAD_ADDR=http://127.0.0.1:4646 nomad acl bootstrap /etc/nomad.d/root.token"
    ]
  }
}
