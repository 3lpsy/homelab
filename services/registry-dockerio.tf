# docker.io pull-through cache. Lives in the shared `registry-proxy`
# namespace alongside registry-ghcrio. Both pods mount the same PVC
# (registry-proxy-data) at different subPaths so their on-disk content
# stays isolated.

resource "kubernetes_secret" "registry_dockerio_tailscale_state" {
  metadata {
    name      = "registry-dockerio-tailscale-state"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }
  type = "Opaque"

  lifecycle {
    ignore_changes = [data, type]
  }
}

resource "headscale_pre_auth_key" "registry_dockerio_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.registry_proxy_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "registry_dockerio_tailscale_auth" {
  metadata {
    name      = "registry-dockerio-tailscale-auth"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.registry_dockerio_server.key
  }
}

module "registry-dockerio-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.registry_dockerio_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "vault_kv_secret_v2" "registry_dockerio_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "registry-dockerio/tls"
  data_json = jsonencode({
    fullchain_pem = module.registry-dockerio-tls.fullchain_pem
    privkey_pem   = module.registry-dockerio-tls.privkey_pem
  })

  # tls-rotator owns rotation post-bootstrap.
  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "kubernetes_manifest" "registry_dockerio_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-registry-dockerio"
      namespace = kubernetes_namespace.registry_proxy.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "registry-dockerio-tls"
          type       = "kubernetes.io/tls"
          data = [
            { objectName = "tls_crt", key = "tls.crt" },
            { objectName = "tls_key", key = "tls.key" },
          ]
        },
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "registry-proxy"
        objects = yamlencode([
          {
            objectName = "tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/registry-dockerio/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/registry-dockerio/tls"
            secretKey  = "privkey_pem"
          },
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.registry_proxy,
    vault_kubernetes_auth_backend_role.registry_proxy,
    vault_kv_secret_v2.registry_dockerio_tls,
    vault_policy.registry_proxy,
  ]
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
      server_domain = "${var.registry_dockerio_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
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
          "secret.reloader.stakater.com/reload" = "registry-dockerio-tls"
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
            value = "registry-dockerio-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.registry_dockerio_tailscale_auth.metadata[0].name
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
          secret { secret_name = "registry-dockerio-tls" }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.registry_dockerio_secret_provider.manifest.metadata.name
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
    kubernetes_manifest.registry_dockerio_secret_provider
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
