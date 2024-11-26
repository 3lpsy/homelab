# resource "null_resource" "install_kernel_deps" {
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
#       "sudo dnf -y install pkg-config ncurses-devel bison flex elfutils-libelf-devel openssl-devel openssl-devel-engine bc perl",
#       "sudo dnf -y group install development-tools c-development"
#     ]
#   }
# }

# resource "null_resource" "download_kernel" {
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
#       "sudo mkdir -p /opt/linux/kernels",
#       "sudo chown ${var.ssh_user}:${var.ssh_user} /opt/linux",
#       "if [[ ! /opt/linux/linux.git ]]; then git clone --depth 1 -b v${var.kernel_version} https://github.com/torvalds/linux.git /opt/linux/linux.git; else echo 'Kernel already exists'; fi"
#     ]
#   }
#   depends_on = [null_resource.install_kernel_deps]
# }

# resource "null_resource" "configure_kernel" {
#   connection {
#     type        = "ssh"
#     host        = var.host
#     user        = var.ssh_user
#     private_key = var.ssh_priv_key
#     timeout     = "1m"
#   }
#   triggers = {
#     config = md5(file("${path.root}/../data/kernel/kernel.config.tpl"))
#   }
#   provisioner "file" {
#     content = file("${path.root}/../data/kernel/kernel.config.tpl"
#     )
#     destination = "/opt/linux/linux.git/.config"
#   }
#   depends_on = [null_resource.download_kernel]
# }

# resource "null_resource" "build_kernel" {
#   connection {
#     type        = "ssh"
#     host        = var.host
#     user        = var.ssh_user
#     private_key = var.ssh_priv_key
#     timeout     = "1m"
#   }
#   provisioner "remote-exec" {
#     inline = [
#       "cd /opt/linux/linux.git",
#       "make -j$(nproc) vmlinux",
#       "cp vmlinux /opt/linux/kernels/vmlinux-${var.kernel_version}.x86_64.bin"
#     ]
#   }
#   depends_on = [null_resource.configure_kernel]
# }
