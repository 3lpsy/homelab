# otelcol-contrib on the Headscale EC2: install, configure, start.
# Ships journald + nginx logs to OpenObserve over the tailnet.

# Read ingester creds populated by the bootstrap Job. depends_on ensures this
# data source is evaluated only after the Job has written the basic_b64 back
# to Vault; on subsequent applies the stored value is read straight through.
data "vault_kv_secret_v2" "openobserve_ingester" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "openobserve/service-accounts/ingester"

  depends_on = [
    kubernetes_manifest.openobserve_bootstrap_job,
  ]
}

locals {
  headscale_otel_config = templatefile("${path.module}/../data/otel/headscale-collector-config.yaml.tpl", {
    openobserve_fqdn = local.openobserve_fqdn
    openobserve_org  = var.openobserve_org
  })
  headscale_otel_env = "OO_AUTH=${data.vault_kv_secret_v2.openobserve_ingester.data["basic_b64"]}\n"
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
    # Bump to force reinstall (e.g. after major otelcol release, or when the
    # inline provisioner steps below change —
    # v2: adm group for nginx
    # v3: SupplementaryGroups in systemd drop-in
    install_version = "v3"
  }

  provisioner "remote-exec" {
    inline = [
      "LATEST=$(curl -fsSL -o /dev/null -w '%%{url_effective}' https://github.com/open-telemetry/opentelemetry-collector-releases/releases/latest | sed 's,.*/tag/v,,')",
      "echo \"Installing otelcol-contrib v$LATEST\"",
      "curl -fsSL -o /tmp/otelcol-contrib.deb \"https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$${LATEST}/otelcol-contrib_$${LATEST}_linux_amd64.deb\"",
      "sudo apt-get install -y /tmp/otelcol-contrib.deb",
      "rm -f /tmp/otelcol-contrib.deb",

      # Systemd drop-in: read auth env from /etc/otelcol-contrib/.env, and
      # grant the service supplementary groups for journal + nginx log reads.
      # systemd services don't inherit /etc/group supplementary groups
      # automatically — they must be declared here.
      "sudo mkdir -p /etc/systemd/system/otelcol-contrib.service.d",
      "sudo tee /etc/systemd/system/otelcol-contrib.service.d/env.conf >/dev/null <<'EOF'",
      "[Service]",
      "EnvironmentFile=-/etc/otelcol-contrib/.env",
      "SupplementaryGroups=adm systemd-journal",
      "EOF",
      "sudo systemctl daemon-reload",

      # Also update /etc/group memberships for consistency (useful for manual
      # debugging as the otelcol-contrib user; systemd itself ignores these).
      "sudo usermod -a -G systemd-journal otelcol-contrib || true",
      "sudo usermod -a -G adm otelcol-contrib || true",
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
      # Always reload units before restart — the install block's earlier
      # daemon-reload can get invalidated by package-level triggers between
      # provisioners, so we re-run it here to guarantee drop-ins are active.
      "sudo systemctl daemon-reload",
      "sudo systemctl restart otelcol-contrib",
    ]
  }

  depends_on = [
    null_resource.headscale_host_otel_install,
    kubernetes_deployment.openobserve,
  ]
}
