resource "kubernetes_stateful_set" "vault" {
  metadata {
    name      = "vault"
    namespace = kubernetes_namespace.vault.metadata[0].name
    labels = {
      app = "vault"
    }
  }
  timeouts {
    create = "2m"
    update = "2m"
    delete = "5m"
  }

  spec {
    service_name = "vault"
    replicas     = 1

    selector {
      match_labels = {
        app = "vault"
      }
    }

    template {
      metadata {
        labels = {
          app = "vault"
        }
        annotations = {
          # Forces pod roll when vault.hcl changes (e.g. log_level tweaks).
          # Without this, CM content updates go unnoticed since the StatefulSet
          # template hash doesn't change on CM-only edits.
          "config-hash" = sha1(kubernetes_config_map.vault_config.data["vault.hcl"])
        }
      }

      spec {
        service_account_name = kubernetes_service_account.vault.metadata[0].name

        init_container {
          name  = "init-permissions"
          image = var.image_busybox
          command = [
            "sh", "-c",
            "chown -R 100:1000 /vault/data && chmod -R 755 /vault/data"
          ]

          volume_mount {
            name       = "vault-data"
            mount_path = "/vault/data"
          }

          security_context {
            run_as_user = 0
          }
        }

        # Vault
        container {
          name  = "vault"
          image = var.image_vault

          command = ["vault"]
          args    = ["server", "-config=/vault/config/vault.hcl"]

          port {
            container_port = 8200
            name           = "vault"
            protocol       = "TCP"
          }

          port {
            container_port = 8201
            name           = "cluster"
            protocol       = "TCP"
          }

          env {
            name  = "VAULT_ADDR"
            value = "http://0.0.0.0:8200"
          }

          env {
            name  = "VAULT_API_ADDR"
            value = "http://vault.vault.svc.cluster.local:8200"
          }

          env {
            name  = "VAULT_CONFIG_DIR"
            value = "/vault/config"
          }

          volume_mount {
            name       = "vault-config"
            mount_path = "/vault/config"
          }

          volume_mount {
            name       = "vault-data"
            mount_path = "/vault/data"
          }

          volume_mount {
            name       = "vault-tls"
            mount_path = "/vault/tls"
            read_only  = true
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }

          security_context {
            run_as_user  = 100
            run_as_group = 1000
          }

          liveness_probe {
            http_get {
              path   = "/v1/sys/health?standbyok=true"
              port   = 8200
              scheme = "HTTP"
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }

          readiness_probe {
            http_get {
              path   = "/v1/sys/health?standbyok=true&uninitcode=200"
              port   = 8200
              scheme = "HTTP"
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 3
            failure_threshold     = 3
          }
        }

        # Vault Volumes
        volume {
          name = "vault-config"
          config_map {
            name = kubernetes_config_map.vault_config.metadata[0].name
          }
        }
        volume {
          name = "vault-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.vault_data.metadata[0].name
          }
        }
        volume {
          name = "vault-tls"
          secret {
            secret_name = kubernetes_secret.vault_tls.metadata[0].name
          }
        }

        # Auto-unseal
        container {
          name    = "auto-unseal"
          image   = var.image_busybox
          command = ["/bin/sh", "/scripts/unseal.sh"]

          env {
            name  = "CHECK_INTERVAL"
            value = "10"
          }

          env {
            name = "UNSEAL_KEY_1"
            value_from {
              secret_key_ref {
                name = "vault-unseal-keys"
                key  = "key1"
              }
            }
          }

          volume_mount {
            name       = "unseal-script"
            mount_path = "/scripts"
            read_only  = true
          }

          resources {
            requests = { cpu = "10m", memory = "16Mi" }
            limits   = { cpu = "50m", memory = "32Mi" }
          }
        }

        # Auto-unseal Volumes
        volume {
          name = "unseal-script"
          config_map {
            name         = kubernetes_config_map.vault_unseal_script.metadata[0].name
            default_mode = "0755"
          }
        }

        # Tailscale
        container {
          name  = "tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }

          env {
            name  = "TS_KUBE_SECRET"
            value = "tailscale-state"
          }

          env {
            name  = "TS_USERSPACE"
            value = "false"
          }

          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }

          env {
            name  = "TS_HOSTNAME"
            value = "vault"
          }

          env {
            name  = "TS_EXTRA_ARGS"
            value = "--login-server=https://${data.terraform_remote_state.homelab.outputs.headscale_server_fqdn}"
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

          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "100m", memory = "64Mi" }
          }
        }

        # Tailscale Volumes
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

resource "kubernetes_service" "vault" {
  metadata {
    name      = "vault"
    namespace = kubernetes_namespace.vault.metadata[0].name
    labels = {
      app = "vault"
    }
  }

  spec {
    selector = {
      app = "vault"
    }

    port {
      name        = "vault"
      port        = 8200
      target_port = 8200
      protocol    = "TCP"
    }

    port {
      name        = "cluster"
      port        = 8201
      target_port = 8201
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}
