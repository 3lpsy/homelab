locals {
  exitnode_names = {
    for f in fileset(var.wireguard_config_dir, "*.conf") :
    lower(trimprefix(trimsuffix(f, ".conf"), "wg-")) => f
  }

  # Strip DNS line from WG configs to preserve Kubernetes DNS resolution
  exitnode_wg_configs = {
    for name, filename in local.exitnode_names : name => join("\n", [
      for line in split("\n", file("${var.wireguard_config_dir}/${filename}")) :
      line if !startswith(trimspace(line), "DNS=") && !startswith(trimspace(line), "DNS ")
    ])
  }
}

resource "kubernetes_deployment" "exitnode" {
  for_each = local.exitnode_names

  timeouts {
    create = "3m"
    update = "3m"
  }

  metadata {
    name      = "exitnode-${each.key}"
    namespace = kubernetes_namespace.exitnode.metadata[0].name
    labels = {
      app = "exitnode-${each.key}"
    }
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        app = "exitnode-${each.key}"
      }
    }

    template {
      metadata {
        labels = {
          app = "exitnode-${each.key}"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.exitnode.metadata[0].name

        # WireGuard — connects to ProtonVPN
        container {
          name  = "wireguard"
          image = var.image_wireguard

          command = ["/bin/sh", "-c"]
          args = [<<-EOT
            cp /wg-secret/wg0.conf /tmp/wg0.conf &&
            DEFAULT_GW=$(ip route | awk '/default/{print $3; exit}') &&
            DEFAULT_DEV=$(ip route | awk '/default/{print $5; exit}') &&
            sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
            sysctl -w net.ipv6.conf.all.forwarding=1 2>/dev/null || true
            sysctl -w net.ipv4.conf.all.src_valid_mark=1 2>/dev/null || true
            wg-quick up /tmp/wg0.conf && {
              ip route add ${var.k8s_pod_cidr} via $DEFAULT_GW dev $DEFAULT_DEV 2>/dev/null
              ip route add ${var.k8s_service_cidr} via $DEFAULT_GW dev $DEFAULT_DEV 2>/dev/null
              exec sleep infinity
            }
          EOT
          ]

          security_context {
            privileged = true
          }

          volume_mount {
            name       = "wg-secret"
            mount_path = "/wg-secret"
            read_only  = true
          }

          volume_mount {
            name       = "dev-net-tun"
            mount_path = "/dev/net/tun"
          }
        }

        # Tailscale — advertises as exit node on headscale
        container {
          name  = "tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }

          env {
            name  = "TS_KUBE_SECRET"
            value = "exitnode-${each.key}-state"
          }

          env {
            name  = "TS_USERSPACE"
            value = "false"
          }

          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.exitnode_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }

          env {
            name  = "TS_HOSTNAME"
            value = "exitnode-${each.key}"
          }

          env {
            name  = "TS_EXTRA_ARGS"
            value = "--login-server=https://${data.terraform_remote_state.homelab.outputs.headscale_server_fqdn} --advertise-exit-node"
          }

          security_context {
            capabilities {
              add = ["NET_ADMIN"]
            }
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
          name = "wg-secret"
          secret {
            secret_name = kubernetes_secret.exitnode_wg_config[each.key].metadata[0].name
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
}
