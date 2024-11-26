
resource "random_uuid" "nomad_acl_token" {}


resource "null_resource" "bootstrap_nomad" {
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
      "sudo NOMAD_ADDR=http://127.0.0.1:4646 nomad acl bootstrap -token ${random_uuid.nomad_acl_token.result} "
    ]
  }
}
