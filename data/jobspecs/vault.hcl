  job "vault-job" {
    datacenters = ["dc1"]
    type        = "service"

    group "vault-group" {
      volume "vault" {
        type = "host"
        read_only = false
        source = "vault"
      }
      volume "ts-vault" {
        type = "host"
        read_only = false
        source = "ts-vault"
      }
      task "ts-vault" {
        driver = "podman"
        lifecycle {
          hook = "prestart"
          sidecar = true
        }
        env {
          TS_AUTHKEY    = "${tailnet_auth_key}"
          TS_EXTRA_ARGS = "--login-server https://${headscale_server_domain} --advertise-tags=tag:${headscale_tag} --reset"
          TS_STATE_DIR  = "/var/lib/tailscale"
          TS_USERSPACE  = "false"
        }
        config {
          image    = "docker.io/tailscale/tailscale:latest"
          hostname = "${hostname}"

          cap_add = ["NET_ADMIN", "SYS_MODULE"]
          devices = ["/dev/net/tun:/dev/net/tun"]
        }

        volume_mount {
          volume      = "ts-vault"
          destination = "/var/lib/tailscale"
          propagation_mode = "private"
        }

        resources {
          cpu    = 500
          memory = 256
        }
        restart {
          attempts = 10
          interval = "5m"
          delay    = "25s"
          mode     = "delay"
        }
      }

      task "nginx-vault" {
        driver = "podman"
        config {
          image        = "docker.io/library/nginx:latest"
          network_mode = "task:ts-vault"
          ports = []
        }

        volume_mount {
          volume      = "vault"
          destination = "/data"
          propagation_mode = "private"
        }
        resources {
          cpu    = 500
          memory = 256
        }
        restart {
          attempts = 10
          interval = "5m"
          delay    = "25s"
          mode     = "delay"
        }
      }
    }
  }
