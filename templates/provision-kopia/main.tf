# Provisions a kopia client on a remote host:
#   1. install        — installs kopia from the upstream apt/dnf repo
#   2. env_file       — drops /etc/kopia/env (root:root, 0600) with creds + repo password
#   3. repo_init      — `connect || create` against the S3 prefix, applies retention policy
#                       and per-path ignore patterns
#   4. systemd        — installs kopia-backup.service + .timer, enables the timer
#
# Re-runs on trigger changes; skips when nothing changed. Caller passes credentials
# through sensitive variables; nothing is committed to disk on the workstation.

locals {
  env_file = <<-EOT
    AWS_ACCESS_KEY_ID=${var.aws_access_key_id}
    AWS_SECRET_ACCESS_KEY=${var.aws_secret_access_key}
    AWS_REGION=${var.bucket_region}
    KOPIA_PASSWORD=${var.repo_password}
    KOPIA_CONFIG_PATH=/var/lib/kopia/repository.config
    KOPIA_CACHE_DIRECTORY=/var/cache/kopia
    KOPIA_LOG_DIR=/var/log/kopia
  EOT

  service_unit = templatefile("${path.root}/../data/kopia/kopia-backup.service.tpl", {
    snapshot_args = join(" ", [for p in var.backup_paths : "'${p}'"])
  })

  timer_unit = templatefile("${path.root}/../data/kopia/kopia-backup.timer.tpl", {
    on_calendar = var.on_calendar
  })
}

resource "null_resource" "install" {
  triggers = {
    # Bump to force a reinstall (e.g. version pin change).
    install_marker = "kopia-stable"
  }

  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "2m"
  }

  provisioner "remote-exec" {
    # Runs under /bin/sh (dash on Ubuntu, bash on Fedora). Stick to POSIX:
    # no `pipefail`, no [[ ]], no process substitution. Pipes are split into
    # discrete steps so set -e catches failures without needing pipefail.
    inline = [
      <<-EOT
        set -eu
        if command -v kopia >/dev/null 2>&1; then
          echo "kopia already installed: $(kopia --version)"
          exit 0
        fi
        . /etc/os-release
        case "$${ID_LIKE:-$${ID}}" in
          *fedora*|*rhel*|*centos*)
            sudo rpm --import https://kopia.io/signing-key
            sudo tee /etc/yum.repos.d/kopia.repo > /dev/null <<'REPO'
        [Kopia]
        name=Kopia
        baseurl=http://packages.kopia.io/rpm/stable/$basearch/
        gpgcheck=1
        enabled=1
        gpgkey=https://kopia.io/signing-key
        REPO
            sudo dnf install -y kopia
            ;;
          *debian*|*ubuntu*)
            sudo install -m 0755 -d /etc/apt/keyrings
            tmpkey=$(mktemp)
            curl -fsSL https://kopia.io/signing-key -o "$tmpkey"
            sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/kopia-keyring.gpg "$tmpkey"
            rm -f "$tmpkey"
            echo "deb [signed-by=/etc/apt/keyrings/kopia-keyring.gpg] http://packages.kopia.io/apt/ stable main" | sudo tee /etc/apt/sources.list.d/kopia.list > /dev/null
            sudo apt-get update
            sudo apt-get install -y kopia
            ;;
          *)
            echo "Unsupported OS for kopia install: $${ID:-unknown}" >&2
            exit 1
            ;;
        esac
        kopia --version
      EOT
    ]
  }
}

resource "null_resource" "env_file" {
  triggers = {
    env = md5(local.env_file)
  }

  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }

  provisioner "file" {
    content     = local.env_file
    destination = "/home/${var.ssh_user}/kopia.env"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p /etc/kopia /var/lib/kopia /var/cache/kopia /var/log/kopia",
      "sudo mv /home/${var.ssh_user}/kopia.env /etc/kopia/env",
      "sudo chown root:root /etc/kopia/env",
      "sudo chmod 600 /etc/kopia/env",
    ]
  }

  depends_on = [null_resource.install]
}

# `connect || create` is the standard kopia bootstrap: connect errors if no
# repo exists at the prefix, create errors if one already does. Exactly one
# wins on any given run. Re-run on bucket/prefix change so a moved repo gets
# re-initialized; password drift after init is NOT auto-handled — rotate by
# nuking the prefix and reapplying.
resource "null_resource" "repo_init" {
  triggers = {
    bucket   = var.bucket_name
    prefix   = var.prefix
    region   = var.bucket_region
    paths    = join(",", var.backup_paths)
    excludes = join(",", var.exclude_globs)
  }

  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
        set -eu
        sudo --preserve-env=AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY,AWS_REGION,KOPIA_PASSWORD,KOPIA_CONFIG_PATH,KOPIA_CACHE_DIRECTORY \
          bash -c '
            set -a; . /etc/kopia/env; set +a
            kopia repository connect s3 \
              --bucket="${var.bucket_name}" \
              --prefix="${var.prefix}" \
              --region="${var.bucket_region}" \
            || kopia repository create s3 \
              --bucket="${var.bucket_name}" \
              --prefix="${var.prefix}" \
              --region="${var.bucket_region}"
            kopia policy set --global \
              --keep-latest=10 \
              --keep-daily=14 \
              --keep-weekly=8 \
              --keep-monthly=12
        '
      EOT
      ,
      # Apply per-path ignore patterns. kopia policy is upsert-style so re-runs
      # are idempotent; removing a glob from var.exclude_globs does NOT clear
      # an existing ignore — manual cleanup required if you ever revoke one.
      length(var.exclude_globs) == 0 ? "echo no-excludes" : <<-EOT
        set -eu
        sudo --preserve-env=AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY,AWS_REGION,KOPIA_PASSWORD,KOPIA_CONFIG_PATH,KOPIA_CACHE_DIRECTORY \
          bash -c '
            set -a; . /etc/kopia/env; set +a
        ${join("\n", flatten([
          for p in var.backup_paths : [
            for ex in var.exclude_globs :
            "    kopia policy set ${p} --add-ignore ${ex} || true"
          ]
        ]))}
        '
      EOT
    ]
  }

  depends_on = [null_resource.env_file]
}

resource "null_resource" "systemd" {
  triggers = {
    service = md5(local.service_unit)
    timer   = md5(local.timer_unit)
  }

  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = var.ssh_priv_key
    timeout     = "1m"
  }

  provisioner "file" {
    content     = local.service_unit
    destination = "/tmp/kopia-backup.service"
  }

  provisioner "file" {
    content     = local.timer_unit
    destination = "/tmp/kopia-backup.timer"
  }

  provisioner "remote-exec" {
    # `install` sets owner+perms atomically; `restorecon` relabels for SELinux
    # (Fedora) so systemd indexes the units as systemd_unit_file_t. On Ubuntu
    # restorecon is absent and `|| true` keeps the script POSIX-portable.
    inline = [
      <<-EOT
        set -eu
        sudo install -m 0644 -o root -g root /tmp/kopia-backup.service /etc/systemd/system/kopia-backup.service
        sudo install -m 0644 -o root -g root /tmp/kopia-backup.timer   /etc/systemd/system/kopia-backup.timer
        rm -f /tmp/kopia-backup.service /tmp/kopia-backup.timer
        command -v restorecon >/dev/null 2>&1 \
          && sudo restorecon -v /etc/systemd/system/kopia-backup.service /etc/systemd/system/kopia-backup.timer \
          || true
        sudo systemctl daemon-reload
        sudo systemctl enable --now kopia-backup.timer
      EOT
    ]
  }

  depends_on = [null_resource.repo_init]
}
