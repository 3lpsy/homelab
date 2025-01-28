# resource "null_resource" "install_deps" {
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
#       "sudo dnf install -y git nginx neovim wget yq"
#     ]
#   }
# }

# # install_containerd
# # install_kata
# # install_firecracker
# # configure_containerd
# # configure_containerd_devmapper
# # containerd_thinpool_loader
# # start_containerd
# # configure_kata
# # upload_images
