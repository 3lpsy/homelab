# docker.io pull-through cache. Lives in the shared `registry-proxy`
# namespace alongside registry-ghcrio. Both pods mount the same PVC
# (registry-proxy-data) at different subPaths so their on-disk content
# stays isolated. Shared SA / Role / Vault policy / auth role live in
# registry-proxy.tf.

module "registry_dockerio_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "registry-dockerio"
  namespace            = kubernetes_namespace.registry_proxy.metadata[0].name
  service_account_name = kubernetes_service_account.registry_proxy.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.registry_proxy_server_user

  # Role/RoleBinding live in registry-proxy.tf (one Role lists every
  # state Secret; this module just creates the state Secret + auth key).
  manage_role = false
}

module "registry_dockerio_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "registry-dockerio"
  namespace            = kubernetes_namespace.registry_proxy.metadata[0].name
  service_account_name = kubernetes_service_account.registry_proxy.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = "${var.registry_dockerio_domain}.${local.magic_fqdn_suffix}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  # Shared registry-proxy Vault policy + auth role live in registry-proxy.tf.
  manage_vault_auth = false
  role_name         = vault_kubernetes_auth_backend_role.registry_proxy.role_name

  providers = { acme = acme }
}

resource "kubernetes_config_map" "registry_dockerio_config" {
  metadata {
    name      = "registry-dockerio-config"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }
  data = {
    "config.yml" = templatefile("${path.module}/../data/registry-proxy/config.yml.tpl", {
      remoteurl     = "https://registry-1.docker.io"
      rootdirectory = "/var/lib/registry"
      listen_port   = "5000"
    })
  }
}

resource "kubernetes_config_map" "registry_dockerio_nginx_config" {
  metadata {
    name      = "registry-dockerio-nginx-config"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/registry-proxy.nginx.conf.tpl", {
      server_domain = "${var.registry_dockerio_domain}.${local.magic_fqdn_suffix}"
      upstream_port = "5000"
    })
  }
}

resource "kubernetes_deployment" "registry_dockerio" {
  metadata {
    name      = "registry-dockerio"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "registry-dockerio" }
    }

    template {
      metadata {
        labels = { app = "registry-dockerio" }
        annotations = {
          "registry-config-hash"                = sha1(kubernetes_config_map.registry_dockerio_config.data["config.yml"])
          "nginx-config-hash"                   = sha1(kubernetes_config_map.registry_dockerio_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = module.registry_dockerio_tls_vault.tls_secret_name
          # Pull-through cache — every layer is regen-able by re-pulling.
          "backup.velero.io/backup-volumes-excludes" = "registry-data"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.registry_proxy.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "tls_crt"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        container {
          name  = "registry-dockerio"
          image = var.image_registry

          # Route upstream pulls through the rotating exit-node front-end.
          # Each TCP connection picks a random ProtonVPN exit, so docker.io's
          # per-IP anonymous rate limit is multiplied by the number of
          # configured exit-nodes.
          # env {
          #   name  = "HTTPS_PROXY"
          #   value = "http://exitnode-haproxy.exitnode.svc.cluster.local:8888"
          # }
          # env {
          #   name  = "HTTP_PROXY"
          #   value = "http://exitnode-haproxy.exitnode.svc.cluster.local:8888"
          # }
          # env {
          #   name  = "NO_PROXY"
          #   value = "${var.k8s_pod_cidr},${var.k8s_service_cidr},127.0.0.1,localhost,.svc,.svc.cluster.local,.cluster.local"
          # }

          port {
            container_port = 5000
            name           = "http"
          }

          volume_mount {
            name       = "registry-data"
            mount_path = "/var/lib/registry"
            sub_path   = "dockerio"
          }
          volume_mount {
            name       = "registry-config"
            mount_path = "/etc/docker/registry/config.yml"
            sub_path   = "config.yml"
            read_only  = true
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 5000
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 5000
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        container {
          name  = "registry-dockerio-nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "registry-dockerio-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }

          resources {
            # See registry.tf for rationale — same TLS handshake CPU
            # ceiling under concurrent BuildKit pull bursts.
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "1", memory = "256Mi" }
          }
        }

        container {
          name  = "registry-dockerio-tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.registry_dockerio_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.registry_dockerio_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.registry_dockerio_domain
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
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
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
          name = "registry-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.registry_proxy_data.metadata[0].name
          }
        }
        volume {
          name = "registry-config"
          config_map {
            name = kubernetes_config_map.registry_dockerio_config.metadata[0].name
          }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.registry_dockerio_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "registry-dockerio-tls"
          secret { secret_name = module.registry_dockerio_tls_vault.tls_secret_name }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.registry_dockerio_tls_vault.spc_name
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
    module.registry_dockerio_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "registry_dockerio" {
  metadata {
    name      = "registry-dockerio"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }
  spec {
    selector = { app = "registry-dockerio" }
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
  }
}
