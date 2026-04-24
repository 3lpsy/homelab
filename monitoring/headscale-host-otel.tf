# otelcol-contrib on the Headscale EC2: install, configure, start.
# Ships journald + nginx logs to OpenObserve over the tailnet.

locals {
  headscale_otel_config = templatefile("${path.module}/../data/otel/headscale-collector-config.yaml.tpl", {
    openobserve_fqdn = local.openobserve_fqdn
    openobserve_org  = var.openobserve_org
  })
  headscale_otel_env = "OO_AUTH=${local.openobserve_basic_b64}\n"
}

resource "null_resource" "headscale_host_otel_install" {
  connection {
    type        = "ssh"
    host        = data.terraform_remote_state.homelab.outputs.headscale_ec2_public_ip
    user        = data.terraform_remote_state.homelab.outputs.headscale_ec2_ssh_user
    private_key = trimspace(file(var.ssh_priv_key_path))
    timeout     = "3m"
  }

  triggers = {
    # Bump to force reinstall (e.g. after major otelcol release)
    install_version = "v1"
  }

  provisioner "remote-exec" {
    inline = [
      "LATEST=$(curl -fsSL -o /dev/null -w '%%{url_effective}' https://github.com/open-telemetry/opentelemetry-collector-releases/releases/latest | sed 's,.*/tag/v,,')",
      "echo \"Installing otelcol-contrib v$LATEST\"",
      "curl -fsSL -o /tmp/otelcol-contrib.deb \"https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$${LATEST}/otelcol-contrib_$${LATEST}_linux_amd64.deb\"",
      "sudo apt-get install -y /tmp/otelcol-contrib.deb",
      "rm -f /tmp/otelcol-contrib.deb",

      # Systemd drop-in: read auth env from /etc/otelcol-contrib/.env
      "sudo mkdir -p /etc/systemd/system/otelcol-contrib.service.d",
      "sudo tee /etc/systemd/system/otelcol-contrib.service.d/env.conf >/dev/null <<'EOF'",
      "[Service]",
      "EnvironmentFile=-/etc/otelcol-contrib/.env",
      "EOF",
      "sudo systemctl daemon-reload",

      # Grant journal read
      "sudo usermod -a -G systemd-journal otelcol-contrib || true",
    ]
  }
}

resource "null_resource" "headscale_host_otel_config" {
  connection {
    type        = "ssh"
    host        = data.terraform_remote_state.homelab.outputs.headscale_ec2_public_ip
    user        = data.terraform_remote_state.homelab.outputs.headscale_ec2_ssh_user
    private_key = trimspace(file(var.ssh_priv_key_path))
    timeout     = "2m"
  }

  triggers = {
    config_hash = sha1(local.headscale_otel_config)
    env_hash    = sha1(local.headscale_otel_env)
  }

  provisioner "file" {
    content     = local.headscale_otel_config
    destination = "/home/${data.terraform_remote_state.homelab.outputs.headscale_ec2_ssh_user}/otelcol-config.yaml"
  }

  provisioner "file" {
    content     = local.headscale_otel_env
    destination = "/home/${data.terraform_remote_state.homelab.outputs.headscale_ec2_ssh_user}/otelcol.env"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p /etc/otelcol-contrib",
      "sudo mv /home/${data.terraform_remote_state.homelab.outputs.headscale_ec2_ssh_user}/otelcol-config.yaml /etc/otelcol-contrib/config.yaml",
      "sudo chown root:root /etc/otelcol-contrib/config.yaml",
      "sudo chmod 644 /etc/otelcol-contrib/config.yaml",
      "sudo mv /home/${data.terraform_remote_state.homelab.outputs.headscale_ec2_ssh_user}/otelcol.env /etc/otelcol-contrib/.env",
      "sudo chown root:otelcol-contrib /etc/otelcol-contrib/.env",
      "sudo chmod 640 /etc/otelcol-contrib/.env",
      "sudo systemctl enable otelcol-contrib",
      "sudo systemctl restart otelcol-contrib",
    ]
  }

  depends_on = [
    null_resource.headscale_host_otel_install,
    kubernetes_deployment.openobserve,
  ]
}
