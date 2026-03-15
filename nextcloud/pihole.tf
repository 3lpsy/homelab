resource "kubernetes_namespace" "pihole" {
  metadata {
    name = "pihole"
  }
}

resource "kubernetes_service_account" "pihole" {
  metadata {
    name      = "pihole"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_role" "pihole_tailscale" {
  metadata {
    name      = "pihole-tailscale"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["create"]
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["pihole-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "pihole_tailscale" {
  metadata {
    name      = "pihole-tailscale"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.pihole_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.pihole.metadata[0].name
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }
}

# Headscale pre-auth key for Pi-hole
resource "headscale_pre_auth_key" "pihole_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.pihole_server
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "pihole_tailscale_auth" {
  metadata {
    name      = "pihole-tailscale-auth"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.pihole_server.key
  }
}

resource "random_password" "pihole_password" {
  length  = 32
  special = false
}

resource "vault_kv_secret_v2" "pihole_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "pihole/config"
  data_json = jsonencode({
    admin_password = random_password.pihole_password.result
  })
}

module "pihole-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.pihole_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "vault_kv_secret_v2" "pihole_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "pihole/tls"
  data_json = jsonencode({
    fullchain_pem = module.pihole-tls.fullchain_pem
    privkey_pem   = module.pihole-tls.privkey_pem
  })
}

resource "vault_policy" "pihole" {
  name = "pihole-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/pihole/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "pihole" {
  backend                          = "kubernetes"
  role_name                        = "pihole"
  bound_service_account_names      = ["pihole"]
  bound_service_account_namespaces = ["pihole"]
  token_policies                   = [vault_policy.pihole.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "pihole_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-pihole"
      namespace = kubernetes_namespace.pihole.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "pihole-secrets"
          type       = "Opaque"
          data = [
            {
              objectName = "admin_password"
              key        = "admin_password"
            }
          ]
        },
        {
          secretName = "pihole-tls"
          type       = "kubernetes.io/tls"
          data = [
            {
              objectName = "tls_crt"
              key        = "tls.crt"
            },
            {
              objectName = "tls_key"
              key        = "tls.key"
            }
          ]
        }
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "pihole"
        objects = yamlencode([
          {
            objectName = "admin_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/pihole/config"
            secretKey  = "admin_password"
          },
          {
            objectName = "tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/pihole/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/pihole/tls"
            secretKey  = "privkey_pem"
          }
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.pihole,
    vault_kubernetes_auth_backend_role.pihole,
    vault_kv_secret_v2.pihole_config,
    vault_kv_secret_v2.pihole_tls,
    vault_policy.pihole
  ]
}

resource "kubernetes_config_map" "pihole_nginx_config" {
  metadata {
    name      = "pihole-nginx-config"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }
  data = {
    "nginx.conf" = <<-EOT
      events {
        worker_connections 1024;
      }
      http {
        upstream pihole {
          server localhost:80;
        }
        server {
          listen 443 ssl;
          server_name ${var.pihole_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain};

          ssl_certificate     /etc/nginx/certs/tls.crt;
          ssl_certificate_key /etc/nginx/certs/tls.key;
          ssl_protocols       TLSv1.2 TLSv1.3;
          ssl_ciphers         HIGH:!aNULL:!MD5;
          ssl_prefer_server_ciphers on;

          add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

          location / {
            proxy_pass http://pihole;
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
          }
        }
      }
    EOT
  }
}

resource "kubernetes_persistent_volume_claim" "pihole_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "pihole-data"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_deployment" "pihole" {
  metadata {
    name      = "pihole"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "pihole" }
    }

    template {
      metadata {
        labels = { app = "pihole" }
      }

      spec {
        service_account_name = kubernetes_service_account.pihole.metadata[0].name


        init_container {
          name  = "wait-for-secrets"
          image = "busybox:latest"
          command = [
            "sh", "-c",
            <<-EOT
              echo 'Waiting for pihole secrets to sync from Vault...'
              TIMEOUT=300
              ELAPSED=0
              until [ -f /mnt/secrets/admin_password ]; do
                if [ $ELAPSED -ge $TIMEOUT ]; then
                  echo "Timeout waiting for secrets after $${TIMEOUT}s"
                  exit 1
                fi
                echo "Still waiting... ($${ELAPSED}s)"
                sleep 5
                ELAPSED=$((ELAPSED + 5))
              done
              echo 'Pihole secrets synced successfully!'
            EOT
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        container {
          name  = "tailscale"
          image = "tailscale/tailscale:latest"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "pihole-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.pihole_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.pihole_domain
          }
          env {
            name  = "TS_EXTRA_ARGS"
            value = "--login-server=https://${data.terraform_remote_state.homelab.outputs.headscale_server_fqdn}"
          }

          security_context {
            capabilities {
              add = ["NET_ADMIN", "NET_BIND_SERVICE", "NET_RAW", "SYS_NICE", "CHOWN"]
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

        container {
          name  = "nginx"
          image = "nginx:alpine"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "pihole-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }

          resources {
            requests = { cpu = "50m",  memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        container {
          name  = "pihole"
          image = "pihole/pihole:latest"

          env {
            name = "FTLCONF_webserver_api_password"
            value_from {
              secret_key_ref {
                name = "pihole-secrets"
                key  = "admin_password"
              }
            }
          }
          env {
            name  = "FTLCONF_dns_upstreams"
            value = "9.9.9.9;149.112.112.112"
          }
          env {
            name  = "FTLCONF_dns_listeningMode"
            value = "all"
          }
          env {
            name  = "TZ"
            value = "America/Chicago"  # or wherever you are
          }


          port {
            container_port = 80
            name           = "http"
          }
          port {
            container_port = 53
            protocol       = "UDP"
            name           = "dns-udp"
          }
          port {
            container_port = 53
            protocol       = "TCP"
            name           = "dns-tcp"
          }

          volume_mount {
            name       = "pihole-data"
            mount_path = "/etc/pihole"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }

          liveness_probe {
            http_get {
              path = "/admin"
              port = 80
            }
            initial_delay_seconds = 60
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/admin"
              port = 80
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        volume {
          name = "pihole-tls"
          secret { secret_name = "pihole-tls" }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.pihole_nginx_config.metadata[0].name
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
        volume {
          name = "pihole-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.pihole_data.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.pihole_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.pihole_secret_provider
  ]
}

resource "kubernetes_service" "pihole_internal" {
  metadata {
    name      = "pihole-internal"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }
  spec {
    selector = { app = "pihole" }
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
    type = "ClusterIP"
  }
}
