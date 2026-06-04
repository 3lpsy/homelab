resource "kubernetes_service_account" "ingest_syncthing" {
  metadata {
    name      = "syncthing"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }
  automount_service_account_token = false
}

resource "random_password" "ingest_syncthing_gui" {
  length  = 32
  special = false
}

# Stable Syncthing identity. The Device ID is derived from the cert, so
# generating both here (and persisting in TF state) keeps the cluster's
# identity stable across pod restarts. Without this, the pod's emptyDir
# reset on every restart, syncthing regenerated a fresh cert, and the
# laptop saw a "device wants to connect" prompt every time.
#
# Rotation: `terraform apply -replace=tls_private_key.ingest_syncthing_device`
# changes the Device ID and the laptop will need to re-trust it.
#
# Syncthing accepts ECDSA P-384 (its current default) — RSA also works but
# produces a longer Device ID and slower handshakes.
resource "tls_private_key" "ingest_syncthing_device" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"
}

resource "tls_self_signed_cert" "ingest_syncthing_device" {
  private_key_pem = tls_private_key.ingest_syncthing_device.private_key_pem

  subject {
    common_name = "syncthing"
  }

  # Syncthing's own generator uses 20 years; match for parity.
  validity_period_hours = 20 * 365 * 24
  early_renewal_hours   = 0
  is_ca_certificate     = false

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
    "client_auth",
  ]
}

module "ingest_syncthing_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "syncthing"
  namespace            = kubernetes_namespace.ingest.metadata[0].name
  service_account_name = kubernetes_service_account.ingest_syncthing.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.syncthing_server_user
}

module "ingest_syncthing_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "syncthing"
  namespace            = kubernetes_namespace.ingest.metadata[0].name
  service_account_name = kubernetes_service_account.ingest_syncthing.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = "${var.ingest_syncthing_domain}.${local.magic_fqdn_suffix}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  config_secrets = {
    gui_password = random_password.ingest_syncthing_gui.result
    device_cert  = tls_self_signed_cert.ingest_syncthing_device.cert_pem
    device_key   = tls_private_key.ingest_syncthing_device.private_key_pem
  }

  providers = { acme = acme }
}

resource "kubernetes_config_map" "ingest_syncthing_nginx_config" {
  metadata {
    name      = "syncthing-nginx-config"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/syncthing.nginx.conf.tpl", {
      server_domain       = "${var.ingest_syncthing_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
      nginx_logging_block = local.nginx_logging_blocks["syncthing"]
    })
  }
}

resource "kubernetes_config_map" "ingest_syncthing_config_template" {
  metadata {
    name      = "syncthing-config-template"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }
  data = {
    "config.xml" = templatefile("${path.module}/../data/syncthing/config.xml.tpl", {
      gui_user               = "admin"
      trusted_devices        = var.ingest_syncthing_trusted_devices
      tailnet_hostnames      = var.tailnet_device_hostnames
      headscale_subdomain    = var.headscale_subdomain
      headscale_magic_domain = var.headscale_magic_domain
    })
  }
}

resource "kubernetes_config_map" "ingest_syncthing_render_script" {
  metadata {
    name      = "syncthing-render-script"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }
  data = {
    "render-config.sh" = templatefile("${path.module}/../data/syncthing/syncthing-config-render.sh.tpl", {
      gui_user     = "admin"
      pip_cooldown = var.pip_proxy_cooldown_value
    })
  }
}

resource "kubernetes_deployment" "ingest_syncthing" {
  metadata {
    name      = "syncthing"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "syncthing" }
    }

    template {
      metadata {
        labels = { app = "syncthing" }
        annotations = {
          "nginx-config-hash"                   = sha1(kubernetes_config_map.ingest_syncthing_nginx_config.data["nginx.conf"])
          "syncthing-config-hash"               = sha1(kubernetes_config_map.ingest_syncthing_config_template.data["config.xml"])
          "render-script-hash"                  = sha1(kubernetes_config_map.ingest_syncthing_render_script.data["render-config.sh"])
          "secret.reloader.stakater.com/reload" = "syncthing-secrets,syncthing-tls"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.ingest_syncthing.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "gui_password"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Render config.xml: bcrypt the GUI password and substitute into the
        # template. Also bcrypt-write /etc/nginx/htpasswd for the GUI proxy.
        init_container {
          name  = "render-config"
          image = var.python_base_image
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            <<-EOT
              sh /scripts/render-config.sh
              uv run --exclude-newer '${var.pip_proxy_cooldown_value}' --with bcrypt python -c "
              import bcrypt, pathlib
              p = pathlib.Path('/mnt/secrets/gui_password').read_text().strip().encode()
              h = bcrypt.hashpw(p, bcrypt.gensalt(rounds=10)).decode()
              pathlib.Path('/htpasswd/htpasswd').write_text(f'admin:{h}\n')
              "
              chmod 0644 /htpasswd/htpasswd
            EOT
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
          volume_mount {
            name       = "config-template"
            mount_path = "/mnt/config-tpl"
            read_only  = true
          }
          volume_mount {
            name       = "render-script"
            mount_path = "/scripts"
            read_only  = true
          }
          volume_mount {
            name       = "syncthing-config-rendered"
            mount_path = "/var/syncthing/config"
          }
          volume_mount {
            name       = "nginx-htpasswd"
            mount_path = "/htpasswd"
          }
        }

        # Ensure dropzone subdirs exist with correct ownership before syncthing starts.
        init_container {
          name  = "init-dropzone-dirs"
          image = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            "mkdir -p /var/syncthing/folders/music /var/syncthing/folders/music/failed /var/syncthing/folders/tmp && chown -R 1000:1000 /var/syncthing/folders"
          ]
          volume_mount {
            name       = "media-dropzone"
            mount_path = "/var/syncthing/folders"
          }
        }

        # Syncthing
        container {
          name  = "syncthing"
          image = var.image_ingest_syncthing
          image_pull_policy = "Always"

          env {
            name  = "STNOUPGRADE"
            value = "true"
          }
          env {
            name  = "STHOMEDIR"
            value = "/var/syncthing/config"
          }

          port {
            container_port = 8384
            name           = "gui"
          }
          port {
            container_port = 22000
            name           = "sync"
            protocol       = "TCP"
          }

          security_context {
            run_as_user  = 1000
            run_as_group = 1000
          }

          volume_mount {
            name       = "syncthing-config-rendered"
            mount_path = "/var/syncthing/config"
          }
          volume_mount {
            name       = "media-dropzone"
            mount_path = "/var/syncthing/folders"
          }

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "1000m", memory = "1Gi" }
          }

          liveness_probe {
            tcp_socket {
              port = 8384
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            tcp_socket {
              port = 8384
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        # Nginx — TLS terminator + basic-auth gate on the GUI.
        container {
          name  = "syncthing-nginx"
          image = var.image_nginx
          image_pull_policy = "Always"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "syncthing-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }
          volume_mount {
            name       = "nginx-htpasswd"
            mount_path = "/etc/nginx/htpasswd"
            sub_path   = "htpasswd"
            read_only  = true
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        # Tailscale ingress sidecar — exposes pod on the tailnet at
        # ingest-syncthing.<headscale-magic-domain>. TS_USERSPACE=false puts
        # the sidecar in the pod netns so 22000 (sync) and 443 (GUI) are
        # reachable on the tailnet IP without TS_SERVE_CONFIG forwarding.
        container {
          name  = "syncthing-tailscale"
          image = var.image_tailscale
          image_pull_policy = "Always"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.ingest_syncthing_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.ingest_syncthing_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.ingest_syncthing_domain
          }
          env {
            name  = "TS_EXTRA_ARGS"
            value = "--login-server=https://${data.terraform_remote_state.homelab.outputs.headscale_server_fqdn}"
          }
          env {
            name  = "TS_TAILSCALED_EXTRA_ARGS"
            value = "--port=41641"
          }

          security_context {
            capabilities {
              add = ["NET_ADMIN"]
            }
          }

          resources {
            requests = { cpu = "20m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "256Mi" }
          }

          volume_mount {
            name       = "dev-net-tun"
            mount_path = "/dev/net/tun"
          }
          volume_mount {
            name       = "tailscale-state"
            mount_path = "/var/lib/tailscale"
          }
        }

        volume {
          name = "media-dropzone"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.media_dropzone.metadata[0].name
          }
        }
        volume {
          name = "syncthing-config-rendered"
          empty_dir {}
        }
        volume {
          name = "config-template"
          config_map {
            name = kubernetes_config_map.ingest_syncthing_config_template.metadata[0].name
          }
        }
        volume {
          name = "render-script"
          config_map {
            name         = kubernetes_config_map.ingest_syncthing_render_script.metadata[0].name
            default_mode = "0755"
          }
        }
        volume {
          name = "nginx-htpasswd"
          empty_dir {}
        }
        volume {
          name = "syncthing-tls"
          secret { secret_name = module.ingest_syncthing_tls_vault.tls_secret_name }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.ingest_syncthing_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.ingest_syncthing_tls_vault.spc_name
            }
          }
        }
        volume {
          name = "dev-net-tun"
          host_path {
            path = "/dev/net/tun"
            type = "CharDevice"
          }
        }
        volume {
          name = "tailscale-state"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [
    module.ingest_syncthing_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}
