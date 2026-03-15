# ============================================================================
# Radicale CalDAV/CardDAV Server - Kubernetes Deployment
# ============================================================================
# Follows the same pattern as Nextcloud/Pi-hole:
#   - Dedicated namespace
#   - Tailscale sidecar (Headscale connectivity, only access path)
#   - Nginx sidecar (TLS termination + basic auth)
#   - Vault CSI for secrets
#   - ACME TLS certs stored in Vault
# ============================================================================

# --- Namespace ---------------------------------------------------------------

resource "kubernetes_namespace" "radicale" {
  metadata {
    name = "radicale"
  }
}

# --- Service Account & RBAC -------------------------------------------------

resource "kubernetes_service_account" "radicale" {
  metadata {
    name      = "radicale"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_role" "radicale_tailscale" {
  metadata {
    name      = "radicale-tailscale"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["create"]
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["radicale-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "radicale_tailscale" {
  metadata {
    name      = "radicale-tailscale"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.radicale_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.radicale.metadata[0].name
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }
}

# --- Headscale Pre-auth Key -------------------------------------------------

resource "headscale_pre_auth_key" "radicale_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.calendar_server
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "radicale_tailscale_auth" {
  metadata {
    name      = "radicale-tailscale-auth"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.radicale_server.key
  }
}

# --- TLS Certificate (ACME) -------------------------------------------------

module "radicale-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.radicale_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

# --- Secrets (generated) -----------------------------------------------------

resource "random_password" "radicale_password" {
  length  = 32
  special = false
}

# --- Vault Secrets -----------------------------------------------------------

resource "vault_kv_secret_v2" "radicale_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "radicale/config"
  data_json = jsonencode({
    radicale_password = random_password.radicale_password.result
  })
}

resource "vault_kv_secret_v2" "radicale_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "radicale/tls"
  data_json = jsonencode({
    fullchain_pem = module.radicale-tls.fullchain_pem
    privkey_pem   = module.radicale-tls.privkey_pem
  })
}

# --- Vault Policy & Auth Role -----------------------------------------------

resource "vault_policy" "radicale" {
  name = "radicale-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/radicale/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "radicale" {
  backend                          = "kubernetes"
  role_name                        = "radicale"
  bound_service_account_names      = ["radicale"]
  bound_service_account_namespaces = ["radicale"]
  token_policies                   = [vault_policy.radicale.name]
  token_ttl                        = 86400
}

# --- SecretProviderClass (Vault CSI) ----------------------------------------

resource "kubernetes_manifest" "radicale_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-radicale"
      namespace = kubernetes_namespace.radicale.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "radicale-secrets"
          type       = "Opaque"
          data = [
            {
              objectName = "radicale_password"
              key        = "radicale_password"
            }
          ]
        },
        {
          secretName = "radicale-tls"
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
        roleName     = "radicale"
        objects = yamlencode([
          {
            objectName = "radicale_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/radicale/config"
            secretKey  = "radicale_password"
          },
          {
            objectName = "tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/radicale/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/radicale/tls"
            secretKey  = "privkey_pem"
          }
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.radicale,
    vault_kubernetes_auth_backend_role.radicale,
    vault_kv_secret_v2.radicale_config,
    vault_kv_secret_v2.radicale_tls,
    vault_policy.radicale
  ]
}

# --- Radicale Config ---------------------------------------------------------

resource "kubernetes_config_map" "radicale_config" {
  metadata {
    name      = "radicale-config"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }
  data = {
    "config" = <<-EOT
      [server]
      hosts = 0.0.0.0:5232
      max_connections = 5
      max_content_length = 100000000
      timeout = 30

      [auth]
      type = http_x_remote_user
      htpasswd_filename = /etc/radicale/users
      htpasswd_encryption = md5
      delay = 1

      [storage]
      filesystem_folder = /var/lib/radicale/collections

      [rights]
      type = from_file
      file = /etc/radicale/rights

      [logging]
      level = warning

      [web]
      type = none
    EOT

    "rights" = <<-EOT
      [root]
      user: .+
      collection:
      permissions: R

      [principal]
      user: .+
      collection: {user}
      permissions: RW

      [calendars]
      user: .+
      collection: {user}/[^/]+
      permissions: rw
    EOT
  }
}

# --- Nginx Config ------------------------------------------------------------

resource "kubernetes_config_map" "radicale_nginx_config" {
  metadata {
    name      = "radicale-nginx-config"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }
  data = {
    "nginx.conf" = <<-EOT
      events {
        worker_connections 1024;
      }
      http {
        upstream radicale {
          server localhost:5232;
        }
        server {
          listen 443 ssl;
          server_name ${var.radicale_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain};

          ssl_certificate     /etc/nginx/certs/tls.crt;
          ssl_certificate_key /etc/nginx/certs/tls.key;
          ssl_protocols       TLSv1.2 TLSv1.3;
          ssl_ciphers         HIGH:!aNULL:!MD5;
          ssl_prefer_server_ciphers on;

          add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

          location /radicale/ {
            proxy_pass        http://radicale/;
            proxy_set_header  X-Script-Name /radicale;
            proxy_set_header  X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header  X-Forwarded-Proto $scheme;
            proxy_set_header  X-Remote-User $remote_user;
            proxy_set_header  Host $http_host;
            auth_basic           "Radicale - Password Required";
            auth_basic_user_file /etc/nginx/htpasswd;
          }

          location = / {
            return 301 /radicale/;
          }

          location = /.well-known/carddav {
            return 301 /radicale/;
          }
          location = /.well-known/caldav {
            return 301 /radicale/;
          }
        }
      }
    EOT
  }
}

# --- Persistent Volume Claim -------------------------------------------------

resource "kubernetes_persistent_volume_claim" "radicale_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "radicale-data"
    namespace = kubernetes_namespace.radicale.metadata[0].name
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

# --- Deployment --------------------------------------------------------------

resource "kubernetes_deployment" "radicale" {
  metadata {
    name      = "radicale"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "radicale" }
    }

    template {
      metadata {
        labels = { app = "radicale" }
      }

      spec {
        service_account_name = kubernetes_service_account.radicale.metadata[0].name

        init_container {
          name  = "wait-for-secrets"
          image = "busybox:latest"
          command = [
            "sh", "-c",
            <<-EOT
              echo 'Waiting for radicale secrets to sync from Vault...'
              TIMEOUT=300
              ELAPSED=0
              until [ -f /mnt/secrets/radicale_password ]; do
                if [ $ELAPSED -ge $TIMEOUT ]; then
                  echo "Timeout waiting for secrets after $${TIMEOUT}s"
                  exit 1
                fi
                echo "Still waiting... ($${ELAPSED}s)"
                sleep 5
                ELAPSED=$((ELAPSED + 5))
              done
              echo 'Radicale secrets synced successfully!'
            EOT
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Generate htpasswd from vault password for both nginx and radicale
        init_container {
                  name  = "setup-auth"
                  image = "python:3-alpine"
                  command = [
                    "sh", "-c",
                    <<-EOT
                      pip install --quiet passlib[bcrypt]
                      python -c "
                      import os
                      from passlib.hash import apr_md5_crypt
                      p = os.environ['RADICALE_PASS']
                      print('jim:' + apr_md5_crypt.hash(p))
                      " > /etc/radicale/users
                      chmod 640 /etc/radicale/users
                      chown 1000:1000 /etc/radicale/users
                      cp /etc/radicale/users /etc/nginx-auth/htpasswd
                      chmod 644 /etc/nginx-auth/htpasswd
                    EOT
                  ]

           env {
             name  = "RADICALE_PASS"
             value_from {
               secret_key_ref {
                 name = "radicale-secrets"
                 key  = "radicale_password"
               }
             }
           }

           volume_mount {
             name       = "secrets-store"
             mount_path = "/mnt/secrets"
             read_only  = true
           }
           volume_mount {
             name       = "radicale-auth"
             mount_path = "/etc/radicale"
           }
           volume_mount {
             name       = "nginx-auth"
             mount_path = "/etc/nginx-auth"
           }
         }

        # Fix ownership on data dir for radicale user (UID 1000 in official image)
        init_container {
          name  = "fix-permissions"
          image = "busybox:latest"
          command = [
            "sh", "-c",
            "chown -R 1000:1000 /var/lib/radicale/collections"
          ]
          volume_mount {
            name       = "radicale-data"
            mount_path = "/var/lib/radicale/collections"
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
            value = "radicale-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.radicale_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.radicale_domain
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

        # --- Nginx TLS termination + basic auth ---
        container {
          name  = "nginx"
          image = "nginx:alpine"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "radicale-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }
          volume_mount {
            name       = "nginx-auth"
            mount_path = "/etc/nginx/htpasswd"
            sub_path   = "htpasswd"
            read_only  = true
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        # --- Radicale (official Kozea image) ---
        container {
          name  = "radicale"
          image = "ghcr.io/kozea/radicale:latest"

          args = ["--config", "/etc/radicale/config"]

          port {
            container_port = 5232
            name           = "http"
          }

          volume_mount {
            name       = "radicale-data"
            mount_path = "/var/lib/radicale/collections"
          }
          volume_mount {
            name       = "radicale-config-vol"
            mount_path = "/etc/radicale/config"
            sub_path   = "config"
          }
          volume_mount {
            name       = "radicale-config-vol"
            mount_path = "/etc/radicale/rights"
            sub_path   = "rights"
          }
          volume_mount {
            name       = "radicale-auth"
            mount_path = "/etc/radicale/users"
            sub_path   = "users"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "250m", memory = "256Mi" }
          }

          liveness_probe {
            tcp_socket {
              port = 5232
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            tcp_socket {
              port = 5232
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        # --- Volumes ---
        volume {
          name = "radicale-tls"
          secret { secret_name = "radicale-tls" }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.radicale_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "radicale-config-vol"
          config_map {
            name = kubernetes_config_map.radicale_config.metadata[0].name
          }
        }
        volume {
          name = "radicale-auth"
          empty_dir {}
        }
        volume {
          name = "nginx-auth"
          empty_dir {}
        }
        volume {
          name = "radicale-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.radicale_data.metadata[0].name
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
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.radicale_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.radicale_secret_provider
  ]
}

# --- Service (internal only) ------------------------------------------------

resource "kubernetes_service" "radicale_internal" {
  metadata {
    name      = "radicale-internal"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }
  spec {
    selector = { app = "radicale" }
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
    type = "ClusterIP"
  }
}

# --- Variable ----------------------------------------------------------------
