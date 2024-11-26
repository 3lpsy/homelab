# # Remove ?
# resource "null_resource" "install_podman" {
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
#       "sudo dnf install -y podman podman-docker"
#     ]
#   }
# }
# # Remove ?, doesn't work
# resource "null_resource" "configure_podman" {
#   connection {
#     type        = "ssh"
#     host        = var.host
#     user        = var.ssh_user
#     private_key = var.ssh_priv_key
#     timeout     = "1m"
#   }
#   triggers = {
#     config = md5(file("${path.root}/../data/podman/containers.conf.tpl"))
#   }


#   provisioner "file" {
#     content     = file("${path.root}/../data/podman/containers.conf.tpl")
#     destination = "/home/${var.ssh_user}/containers.conf"
#   }
#   provisioner "remote-exec" {
#     inline = [
#       "sudo mv /home/${var.ssh_user}/containers.conf /etc/containers/containers.conf",
#       "sudo chown root:root /etc/containers/containers.conf",
#       "sudo chmod 644 /etc/containers/containers.conf"
#     ]
#   }
#   depends_on = [null_resource.install_podman]
# }
