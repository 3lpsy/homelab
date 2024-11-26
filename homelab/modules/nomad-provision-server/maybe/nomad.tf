


# resource "null_resource" "install_nomad" {
#   connection {
#     type        = "ssh"
#     host        = var.host
#     user        = var.ssh_user
#     private_key = var.ssh_priv_key
#     timeout     = "1m"
#   }
#   # Set permissions and optionally run a command
#   provisioner "remote-exec" {
#     inline = [
#       "sudo dnf install -y dnf-plugins-core",
#       "sudo dnf config-manager addrepo --from-repofile=https://rpm.releases.hashicorp.com/fedora/hashicorp.repo",
#       "sudo dnf install -y nomad",
#       "sudo systemctl enable nomad"
#     ]
#   }
# }

# resource "null_resource" "configure_nomad" {
#   connection {
#     type        = "ssh"
#     host        = var.host
#     user        = var.ssh_user
#     private_key = var.ssh_priv_key
#     timeout     = "1m"
#   }
#   triggers = {
#     nomad_config    = md5(file("${path.root}/../data/nomad.hcl.tpl"))
#     nomad_host_name = md5(var.nomad_host_name)
#   }
#   # Copy the fullchain.pem to the remote server
#   provisioner "file" {
#     content = templatefile("${path.root}/../data/nomad.hcl.tpl", {
#       nomad_host_name = var.nomad_host_name
#       }
#     )
#     destination = "/home/${var.ssh_user}/nomad.hcl"
#   }
#   provisioner "remote-exec" {
#     inline = [
#       "sudo mv /home/${var.ssh_user}/nomad.hcl /etc/nomad.d/nomad.hcl",
#       "sudo chown -R nomad:nomad /etc/nomad.d/",
#       "sudo chmod -R 644 /etc/nomad.d/",
#       "sudo systemctl restart nomad"
#     ]
#   }
#   depends_on = [null_resource.install_nomad]
# }
