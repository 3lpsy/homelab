# TODO: whatif fedora
#
resource "null_resource" "install_deps" {
  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }
  provisioner "file" {
    content     = file("${path.root}/../data/server/50unattended-upgrades.tpl")
    destination = "/home/${var.ssh_user}/50unattended-upgrades"
  }
  # Set permissions and optionally run a command
  provisioner "remote-exec" {
    inline = [
      "sudo DEBIAN_FRONTEND=noninteractive apt update",
      "sudo DEBIAN_FRONTEND=noninteractive apt install unattended-upgrades nginx curl unzip openssl age -y"
    ]
  }
  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/${var.ssh_user}/50unattended-upgrades /etc/apt/apt.conf.d/50unattended-upgrades",
      "sudo chown root:root /etc/apt/apt.conf.d/50unattended-upgrades",
      "sudo chmod 644 /etc/apt/apt.conf.d/50unattended-upgrades"
    ]
  }
  provisioner "remote-exec" {
    inline = [
      "curl 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o 'awscliv2.zip'",
      "unzip awscliv2.zip",
      "sudo DEBIAN_FRONTEND=noninteractive  ./aws/install",
      "rm -rf aws",
      "rm awscliv2.zip",
      "(echo 'export PATH=/usr/local/bin:$PATH'; cat /etc/profile) > /tmp/profile.tmp",
      "sudo mv /tmp/profile.tmp /etc/profile",
      "sudo chown root:root /etc/profile",
      "sudo chmod 644 /etc/profile"
    ]
  }
  provisioner "remote-exec" {
    inline = [
      "sudo DEBIAN_FRONTEND=noninteractive which headscale || (sudo wget -O /usr/local/bin/headscale 'https://github.com/juanfont/headscale/releases/download/v${var.headscale_version}/headscale_${var.headscale_version}_linux_amd64' && sudo chmod +x /usr/local/bin/headscale)",
      "sudo grep headscale /etc/passwd || sudo useradd -d /var/lib/headscale -m -G ssl-cert -s /usr/sbin/nologin headscale"
    ]
  }
}
