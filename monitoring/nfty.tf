resource "random_password" "ntfy_user_passwords" {
  for_each = var.ntfy_users
  length   = 32
  special  = false
}

resource "kubernetes_service_account" "ntfy" {
  metadata {
    name      = "ntfy"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_role" "ntfy_tailscale" {
  metadata {
    name      = "ntfy-tailscale"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["create"]
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["ntfy-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "ntfy_tailscale" {
  metadata {
    name      = "ntfy-tailscale"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.ntfy_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.ntfy.metadata[0].name
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
}

resource "headscale_pre_auth_key" "ntfy_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.ntfy_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "ntfy_tailscale_auth" {
  metadata {
    name      = "ntfy-tailscale-auth"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.ntfy_server.key
  }
}

module "ntfy-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.ntfy_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

# --- Vault Secrets -----------------------------------------------------------

resource "vault_kv_secret_v2" "ntfy_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "ntfy/config"
  data_json = jsonencode({
    for user, role in var.ntfy_users :
    "password_${user}" => random_password.ntfy_user_passwords[user].result
  })
}

resource "vault_kv_secret_v2" "ntfy_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "ntfy/tls"
  data_json = jsonencode({
    fullchain_pem = module.ntfy-tls.fullchain_pem
    privkey_pem   = module.ntfy-tls.privkey_pem
  })
}

resource "vault_policy" "ntfy" {
  name = "ntfy-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/ntfy/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "ntfy" {
  backend                          = "kubernetes"
  role_name                        = "ntfy"
  bound_service_account_names      = ["ntfy"]
  bound_service_account_namespaces = ["monitoring"]
  token_policies                   = [vault_policy.ntfy.name]
  token_ttl                        = 86400
}

# --- ntfy Server Config (pre-generated with bcrypt hashes) -------------------

resource "kubernetes_config_map" "ntfy_server_config" {
  metadata {
    name      = "ntfy-server-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "server.yml" = yamlencode({
      "base-url"            = "https://${var.ntfy_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
      "listen-http"         = ":8080"
      "cache-file"          = "/var/cache/ntfy/cache.db"
      "cache-duration"      = "24h"
      "auth-file"           = "/var/lib/ntfy/user.db"
      "auth-default-access" = "deny-all"
      "behind-proxy"        = true
      "upstream-base-url"   = "https://ntfy.sh"
      "enable-signup"       = false
      "enable-login"        = true
      "log-level"           = "info"
      "log-format"          = "json"
      "auth-users" = [
        for user, role in var.ntfy_users :
        "${user}:${bcrypt(random_password.ntfy_user_passwords[user].result)}:${role}"
      ]
      "auth-access" = [
        for user, role in var.ntfy_users :
        "${user}:*:rw" if role == "user"
      ]
    })
  }

  lifecycle {
    ignore_changes = [data]
  }
}

# --- Vault CSI (TLS only) ----------------------------------------------------

resource "kubernetes_manifest" "ntfy_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-ntfy"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "ntfy-tls"
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
        roleName     = "ntfy"
        objects = yamlencode([
          {
            objectName = "tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/ntfy/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/ntfy/tls"
            secretKey  = "privkey_pem"
          }
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.monitoring,
    vault_kubernetes_auth_backend_role.ntfy,
    vault_kv_secret_v2.ntfy_tls,
    vault_policy.ntfy
  ]
}

# --- Nginx Config ------------------------------------------------------------

resource "kubernetes_config_map" "ntfy_nginx_config" {
  metadata {
    name      = "ntfy-nginx-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "nginx.conf" = <<-EOT
      events {
        worker_connections 1024;
      }
      http {
        upstream ntfy {
          server localhost:8080;
        }

        map $http_upgrade $connection_upgrade {
          default upgrade;
          '' close;
        }

        server {
          listen 443 ssl;
          server_name ${var.ntfy_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain};

          ssl_certificate     /etc/nginx/certs/tls.crt;
          ssl_certificate_key /etc/nginx/certs/tls.key;
          ssl_protocols       TLSv1.2 TLSv1.3;
          ssl_ciphers         HIGH:!aNULL:!MD5;
          ssl_prefer_server_ciphers on;

          add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

          location / {
            proxy_pass http://ntfy;
            proxy_http_version 1.1;
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;

            proxy_read_timeout 86400s;
            proxy_send_timeout 86400s;

            proxy_buffering off;
          }
        }
      }
    EOT
  }
}

# --- PVC ---------------------------------------------------------------------

resource "kubernetes_persistent_volume_claim" "ntfy_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "ntfy-data"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.ntfy_storage_size
      }
    }
  }
  wait_until_bound = false
}

# --- Deployment --------------------------------------------------------------

resource "kubernetes_deployment" "ntfy" {
  metadata {
    name      = "ntfy"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "ntfy" }
    }

    template {
      metadata {
        labels = { app = "ntfy" }
      }

      spec {
        service_account_name = kubernetes_service_account.ntfy.metadata[0].name

        # Fix permissions on data dir
        init_container {
          name  = "fix-permissions"
          image = "busybox:latest"
          command = [
            "sh", "-c",
            "chown -R 1000:1000 /var/lib/ntfy && chown -R 1000:1000 /var/cache/ntfy"
          ]
          volume_mount {
            name       = "ntfy-data"
            mount_path = "/var/lib/ntfy"
          }
          volume_mount {
            name       = "ntfy-cache"
            mount_path = "/var/cache/ntfy"
          }
        }

        # --- Tailscale sidecar ---
        container {
          name  = "tailscale"
          image = "tailscale/tailscale:latest"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = "ntfy-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.ntfy_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.ntfy_domain
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
        }

        # --- Nginx TLS termination ---
        container {
          name  = "nginx"
          image = "nginx:alpine"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "ntfy-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        # --- ntfy server ---
        container {
          name  = "ntfy"
          image = "binwiederhier/ntfy:latest"

          args = ["serve"]

          port {
            container_port = 8080
            name           = "http"
          }

          volume_mount {
            name       = "ntfy-config"
            mount_path = "/etc/ntfy"
            read_only  = true
          }
          volume_mount {
            name       = "ntfy-data"
            mount_path = "/var/lib/ntfy"
          }
          volume_mount {
            name       = "ntfy-cache"
            mount_path = "/var/cache/ntfy"
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "250m", memory = "256Mi" }
          }

          liveness_probe {
            http_get {
              path = "/v1/health"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/v1/health"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        # --- Volumes ---
        volume {
          name = "ntfy-tls"
          secret { secret_name = "ntfy-tls" }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.ntfy_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "ntfy-config"
          config_map {
            name = kubernetes_config_map.ntfy_server_config.metadata[0].name
          }
        }
        volume {
          name = "ntfy-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.ntfy_data.metadata[0].name
          }
        }
        volume {
          name = "ntfy-cache"
          empty_dir {}
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
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.ntfy_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.ntfy_secret_provider
  ]
}
