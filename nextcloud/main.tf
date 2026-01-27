terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    headscale = {
      source  = "awlsring/headscale"
      version = "~> 0.4.0"
    }
    acme = {
      source  = "vancluever/acme"
      version = "~> 2.0"
    }
  }
}

provider "kubernetes" {
  config_path = pathexpand("/home/vanguard/.config/kube/config")
}

provider "vault" {
  address = "https://vault.${var.headscale_subdomain}.${var.headscale_magic_domain}:8201"
  token   = var.vault_root_token # Store this in a variable or use VAULT_TOKEN env var
}

provider "headscale" {
  endpoint = "https://${data.terraform_remote_state.homelab.outputs.headscale_server_fqdn}"
  api_key  = var.headscale_api_key
}

provider "acme" {
  server_url = var.acme_server_url
}

# Generate Headscale pre-auth key
resource "headscale_pre_auth_key" "nextcloud_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.nextcloud_server
  reusable       = true
  time_to_expire = "1y"
}

# Generate Headscale pre-auth key for Collabora
resource "headscale_pre_auth_key" "collabora_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.collabora_server
  reusable       = true
  time_to_expire = "1y"
}

# Generate TLS certificate
module "nextcloud-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = {
    acme = acme
  }
}


# Generate TLS certificate for Collabora
module "collabora-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = {
    acme = acme
  }
}

# Generate random passwords
resource "random_password" "nextcloud_admin" {
  length  = 32
  special = true
}

resource "random_password" "postgres_password" {
  length  = 32
  special = false
}

resource "random_password" "redis_password" {
  length  = 32
  special = false
}

resource "random_password" "collabora_password" {
  length  = 32
  special = false
}

# Store TLS certs in Vault
resource "vault_kv_secret_v2" "nextcloud_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "nextcloud/tls"

  data_json = jsonencode({
    fullchain_pem = module.nextcloud-tls.fullchain_pem
    privkey_pem   = module.nextcloud-tls.privkey_pem
  })
}

# Store Collabora TLS certs in Vault
resource "vault_kv_secret_v2" "collabora_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "nextcloud/collabora-tls"

  data_json = jsonencode({
    fullchain_pem = module.collabora-tls.fullchain_pem
    privkey_pem   = module.collabora-tls.privkey_pem
  })
}

# Store secrets in Vault
resource "vault_kv_secret_v2" "nextcloud" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "nextcloud/config"

  data_json = jsonencode({
    admin_password     = random_password.nextcloud_admin.result
    postgres_password  = random_password.postgres_password.result
    redis_password     = random_password.redis_password.result
    collabora_password = random_password.collabora_password.result
  })
}

# Generate HaRP shared key
resource "random_password" "harp_shared_key" {
  length  = 32
  special = false
}

# Store HaRP secret in Vault
resource "vault_kv_secret_v2" "harp" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "nextcloud/harp"

  data_json = jsonencode({
    shared_key = random_password.harp_shared_key.result
  })
}

# Create Vault policy for Nextcloud
resource "vault_policy" "nextcloud" {
  name = "nextcloud-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/*" {
  capabilities = ["read"]
}
EOT
}

# Create Vault role for Nextcloud
resource "vault_kubernetes_auth_backend_role" "nextcloud" {
  backend                          = "kubernetes"
  role_name                        = "nextcloud"
  bound_service_account_names      = ["nextcloud"]
  bound_service_account_namespaces = ["nextcloud"]
  token_policies                   = [vault_policy.nextcloud.name]
  token_ttl                        = 86400
}

# Create namespace
resource "kubernetes_namespace" "nextcloud" {
  metadata {
    name = "nextcloud"
  }
}

# Service Account for Nextcloud
resource "kubernetes_service_account" "nextcloud" {
  metadata {
    name      = "nextcloud"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  automount_service_account_token = false
}

# Role for Tailscale
resource "kubernetes_role" "tailscale" {
  metadata {
    name      = "tailscale"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["create"]
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["tailscale-state", "collabora-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "tailscale" {
  metadata {
    name      = "tailscale"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.nextcloud.metadata[0].name
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
}

# Tailscale auth secret
resource "kubernetes_secret" "tailscale_auth" {
  metadata {
    name      = "tailscale-auth"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  type = "Opaque"

  data = {
    TS_AUTHKEY = headscale_pre_auth_key.nextcloud_server.key
  }
}

# SecretProviderClass for Nextcloud secrets from Vault
resource "kubernetes_manifest" "nextcloud_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-nextcloud"
      namespace = kubernetes_namespace.nextcloud.metadata[0].name
    }
    spec = {
      provider = "vault"
      # Sync secrets to Kubernetes secrets for easy consumption
      secretObjects = [
        {
          secretName = "nextcloud-secrets"
          type       = "Opaque"
          data = [
            {
              objectName = "admin_password"
              key        = "admin_password"
            },
            {
              objectName = "postgres_password"
              key        = "postgres_password"
            },
            {
              objectName = "redis_password"
              key        = "redis_password"
            },
            {
              objectName = "harp_shared_key"
              key        = "harp_shared_key"
            },
            {
              objectName = "collabora_password"
              key        = "collabora_password"
            }
          ]
        },
        {
          secretName = "nextcloud-tls"
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
        },
        {
          secretName = "collabora-tls"
          type       = "kubernetes.io/tls"
          data = [
            {
              objectName = "collabora_tls_crt"
              key        = "tls.crt"
            },
            {
              objectName = "collabora_tls_key"
              key        = "tls.key"
            }
          ]
        }
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "nextcloud"
        objects = yamlencode([
          {
            objectName = "admin_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/config"
            secretKey  = "admin_password"
          },
          {
            objectName = "postgres_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/config"
            secretKey  = "postgres_password"
          },
          {
            objectName = "redis_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/config"
            secretKey  = "redis_password"
          },
          {
            objectName = "tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/tls"
            secretKey  = "privkey_pem"
          },
          {
            objectName = "harp_shared_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/harp"
            secretKey  = "shared_key"
          },
          {
            objectName = "collabora_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/config"
            secretKey  = "collabora_password"
          },
          {
            objectName = "collabora_tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/collabora-tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "collabora_tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/nextcloud/collabora-tls"
            secretKey  = "privkey_pem"
          }
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.nextcloud,
    vault_kubernetes_auth_backend_role.nextcloud,
    vault_kv_secret_v2.nextcloud,
    vault_kv_secret_v2.nextcloud_tls,
    vault_kv_secret_v2.harp,
    vault_kv_secret_v2.collabora_tls
  ]
}


# Nginx config
resource "kubernetes_config_map" "nginx_config" {
  metadata {
    name      = "nginx-config"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  data = {
    "nginx.conf" = <<-EOT
      events {
        worker_connections 1024;
      }
      http {
        access_log /var/log/nginx/access.log;
        error_log /var/log/nginx/error.log;

        upstream nextcloud {
          server localhost:80;
        }

        upstream harp {
          server appapi-harp:8780;
        }

        server {
          listen 443 ssl http2;
          server_name ${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain};

          # SSL configuration
          ssl_certificate /etc/nginx/certs/tls.crt;
          ssl_certificate_key /etc/nginx/certs/tls.key;
          ssl_protocols TLSv1.2 TLSv1.3;
          ssl_ciphers HIGH:!aNULL:!MD5;
          ssl_prefer_server_ciphers on;

          # Proxy
          set_real_ip_from 127.0.0.1;
          set_real_ip_from ::1;
          real_ip_header X-Forwarded-For;
          real_ip_recursive on;


          # File upload limits
          client_max_body_size 10G;
          client_body_buffer_size 400M;

          # Timeouts for large file operations
          proxy_connect_timeout 3600;
          proxy_send_timeout 3600;
          proxy_read_timeout 3600;
          send_timeout 3600;

          # Add headers for security
          add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
          add_header X-Content-Type-Options "nosniff" always;
          add_header X-Frame-Options "SAMEORIGIN" always;
          add_header X-XSS-Protection "1; mode=block" always;
          add_header Referrer-Policy "no-referrer" always;
          add_header X-Robots-Tag "noindex, nofollow" always;

          location /exapps/ {
              proxy_pass http://harp;
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_set_header X-Forwarded-Host $host;
              proxy_set_header X-Forwarded-Port $server_port;

              # WebSocket support for ExApps
              proxy_http_version 1.1;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection "upgrade";

              # Disable buffering for streaming
              proxy_buffering off;
              proxy_request_buffering off;
            }

          # Nextcloud CalDAV/CardDAV redirects
          location = /.well-known/carddav {
            return 301 https://$host/remote.php/dav;
          }

          location = /.well-known/caldav {
            return 301 https://$host/remote.php/dav;
          }

          location / {
            proxy_pass http://nextcloud;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-Forwarded-Host $host;
            proxy_set_header X-Forwarded-Port $server_port;

            # Essential for Nextcloud
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_max_temp_file_size 0;
          }

        }
      }
    EOT
  }
}



# PVC for Nextcloud data
resource "kubernetes_persistent_volume_claim" "nextcloud_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "nextcloud-data"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"

    resources {
      requests = {
        storage = "50Gi"
      }
    }
  }
  wait_until_bound = false
}

# PVC for PostgreSQL
resource "kubernetes_persistent_volume_claim" "postgres_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "postgres-data"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"

    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
  wait_until_bound = false
}

# PostgreSQL Deployment
resource "kubernetes_deployment" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "postgres"
      }
    }

    template {
      metadata {
        labels = {
          app = "postgres"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name

        container {
          name  = "postgres"
          image = "postgres:15-alpine"

          env {
            name  = "POSTGRES_DB"
            value = "nextcloud"
          }

          env {
            name  = "POSTGRES_USER"
            value = "nextcloud"
          }
          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = "nextcloud-secrets"
                key  = "postgres_password"
              }
            }
          }

          port {
            container_port = 5432
          }

          volume_mount {
            name       = "postgres-data"
            mount_path = "/var/lib/postgresql/data"
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }

          liveness_probe {
            exec {
              command = ["pg_isready", "-U", "nextcloud"]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          readiness_probe {
            exec {
              command = ["pg_isready", "-U", "nextcloud"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }

        volume {
          name = "postgres-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.postgres_data.metadata[0].name
          }
        }

        # CSI sync?
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.nextcloud_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.nextcloud_secret_provider
  ]
}

# PostgreSQL Service
resource "kubernetes_service" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    selector = {
      app = "postgres"
    }

    port {
      port        = 5432
      target_port = 5432
    }
  }
}


# Redis Deployment
resource "kubernetes_deployment" "redis" {
  metadata {
    name      = "redis"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "redis"
      }
    }

    template {
      metadata {
        labels = {
          app = "redis"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name

        container {
          name  = "redis"
          image = "redis:7-alpine"

          command = [
            "redis-server",
            "--requirepass",
            "$(REDIS_PASSWORD)"
          ]

          env {
            name = "REDIS_PASSWORD"
            value_from {
              secret_key_ref {
                name = "nextcloud-secrets"
                key  = "redis_password"
              }
            }
          }

          port {
            container_port = 6379
          }

          # Mount the CSI volume to trigger secret sync
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          liveness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          readiness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }

        # Mount the CSI volume for secret sync?
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.nextcloud_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.nextcloud_secret_provider
  ]
}

# Redis Service
resource "kubernetes_service" "redis" {
  metadata {
    name      = "redis"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    selector = {
      app = "redis"
    }

    port {
      port        = 6379
      target_port = 6379
    }
  }
}

# Nextcloud Deployment
resource "kubernetes_deployment" "nextcloud" {
  metadata {
    name      = "nextcloud"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "nextcloud"
      }
    }


    template {
      metadata {
        labels = {
          app = "nextcloud"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name
        host_aliases {
          ip = kubernetes_service.collabora_internal.spec[0].cluster_ip
          hostnames = [
            "${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          ]
        }
        # Tailscale sidecar
        container {
          name  = "tailscale"
          image = "tailscale/tailscale:latest"

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
            value = var.nextcloud_domain
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

        # Nginx reverse proxy for TLS termination
        container {
          name  = "nginx"
          image = "nginx:alpine"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "nextcloud-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }

          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }
        }

        # Nextcloud container
        container {
          name  = "nextcloud"
          image = "nextcloud:latest"

          port {
            container_port = 80
          }

          env {
            name  = "POSTGRES_HOST"
            value = "postgres"
          }

          env {
            name  = "POSTGRES_DB"
            value = "nextcloud"
          }

          env {
            name  = "POSTGRES_USER"
            value = "nextcloud"
          }

          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = "nextcloud-secrets"
                key  = "postgres_password"
              }
            }
          }

          env {
            name  = "REDIS_HOST"
            value = "redis"
          }

          env {
            name = "REDIS_HOST_PASSWORD"
            value_from {
              secret_key_ref {
                name = "nextcloud-secrets"
                key  = "redis_password"
              }
            }
          }

          env {
            name  = "REDIS_HOST_PORT"
            value = "6379"
          }

          env {
            name  = "NEXTCLOUD_ADMIN_USER"
            value = var.nextcloud_admin_user
          }

          env {
            name = "NEXTCLOUD_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = "nextcloud-secrets"
                key  = "admin_password"
              }
            }
          }
          env {
            name  = "NEXTCLOUD_CSP_ALLOWED_DOMAINS"
            value = "${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }

          env {
            name  = "NEXTCLOUD_TRUSTED_DOMAINS"
            value = "${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }

          env {
            name  = "OVERWRITEPROTOCOL"
            value = "https"
          }

          env {
            name  = "OVERWRITEHOST"
            value = "${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }

          env {
            name  = "OVERWRITECLIURL"
            value = "https://${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }

          env {
            name  = "TRUSTED_PROXIES"
            value = "127.0.0.1 ::1 10.42.0.0/16 10.43.0.0/16"
          }

          volume_mount {
            name       = "nextcloud-data"
            mount_path = "/var/www/html"
          }

          # Mount the CSI volume to trigger secret sync
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "500m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "2000m"
              memory = "2Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/status.php"
              port = 80
              http_header {
                name  = "Host"
                value = "${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
              }
            }
            initial_delay_seconds = 180
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }

          readiness_probe {
            http_get {
              path = "/status.php"
              port = 80
              http_header {
                name  = "Host"
                value = "${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
              }
            }
            initial_delay_seconds = 120
            period_seconds        = 10
            timeout_seconds       = 3
            failure_threshold     = 30
          }
        }

        volume {
          name = "nextcloud-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.nextcloud_data.metadata[0].name
          }
        }

        volume {
          name = "nextcloud-tls"
          secret {
            secret_name = "nextcloud-tls"
          }
        }

        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.nginx_config.metadata[0].name
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

        # Mount the CSI volume for secret sync
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.nextcloud_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.nextcloud_secret_provider,
    kubernetes_service.postgres,
    kubernetes_service.redis
  ]
}
resource "kubernetes_service" "nextcloud_internal" {
  metadata {
    name      = "nextcloud-internal"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    selector = {
      app = "nextcloud"
    }

    port {
      name        = "https" # Changed from "http"
      port        = 443     # Changed from 80
      target_port = 443     # Point to nginx's HTTPS port
    }

    type = "ClusterIP"
  }
}

# HaRP Deployment with Docker-in-Docker
resource "kubernetes_deployment" "harp" {
  metadata {
    name      = "appapi-harp"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    # replicas = 1

    selector {
      match_labels = {
        app = "appapi-harp"
      }
    }

    template {
      metadata {
        labels = {
          app = "appapi-harp"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name
        init_container {
          name  = "wait-for-secrets"
          image = "busybox:latest"

          command = [
            "sh",
            "-c",
            <<-EOT
                  echo 'Waiting for secrets to sync from Vault...'
                  TIMEOUT=300
                  ELAPSED=0
                  until [ -f /mnt/secrets/harp_shared_key ]; do
                    if [ $ELAPSED -ge $TIMEOUT ]; then
                      echo "Timeout waiting for secrets after $${TIMEOUT}s"
                      exit 1
                    fi
                    echo "Still waiting... ($${ELAPSED}s)"
                    sleep 5
                    ELAPSED=$((ELAPSED + 5))
                  done
                  echo 'Secrets synced successfully!'
                  ls -la /mnt/secrets/
                EOT
          ]

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Docker-in-Docker sidecar
        container {
          name  = "dind"
          image = "docker:dind"

          security_context {
            privileged = true
          }

          startup_probe {
            exec {
              command = ["sh", "-c", "test -S /var/run/docker.sock"]
            }
            initial_delay_seconds = 5
            period_seconds        = 2
            failure_threshold     = 60
          }



          readiness_probe {
            exec {
              command = ["docker", "info"]
            }
            initial_delay_seconds = 5
            period_seconds        = 2
          }


          env {
            name  = "DOCKER_TLS_CERTDIR"
            value = ""
          }

          volume_mount {
            name       = "docker-graph-storage"
            mount_path = "/var/lib/docker"
          }

          volume_mount {
            name       = "docker-socket"
            mount_path = "/var/run"
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "2000m"
              memory = "4Gi"
            }
          }
        }

        # HaRP container
        container {
          name  = "harp"
          image = "ghcr.io/nextcloud/nextcloud-appapi-harp:release"
          command = [
            "sh",
            "-c",
            <<-EOT
                echo 'Waiting for Docker socket...'
                TIMEOUT=120
                ELAPSED=0
                until [ -S /var/run/docker.sock ]; do
                  if [ $ELAPSED -ge $TIMEOUT ]; then
                    echo "Timeout waiting for Docker socket after $${TIMEOUT}s"
                    exit 1
                  fi
                  echo "Still waiting for socket... ($${ELAPSED}s)"
                  sleep 2
                  ELAPSED=$((ELAPSED + 2))
                done
                echo 'Docker socket found!'
                ls -la /var/run/docker.sock
                echo 'Starting HaRP with original entrypoint...'
                exec /usr/local/bin/start.sh
              EOT
          ]
          env {
            name = "HP_SHARED_KEY"
            value_from {
              secret_key_ref {
                name = "nextcloud-secrets"
                key  = "harp_shared_key"
              }
            }
          }

          env {
            name  = "HP_LOG_LEVEL"
            value = "debug" # Changed from info
          }

          # ADD THIS
          env {
            name  = "HP_VERBOSE_START"
            value = "1"
          }

          env {
            name  = "NC_INSTANCE_URL"
            value = "https://${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }


          port {
            container_port = 8780
            name           = "http"
          }

          port {
            container_port = 8782
            name           = "frp"
          }

          volume_mount {
            name       = "docker-socket"
            mount_path = "/var/run"
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }



          liveness_probe {
            tcp_socket {
              port = 8780
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          readiness_probe {
            tcp_socket {
              port = 8780
            }
            initial_delay_seconds = 10
            period_seconds        = 5
          }
        }

        volume {
          name = "docker-graph-storage"
          empty_dir {}
        }

        volume {
          name = "docker-socket"
          empty_dir {}
        }

        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.nextcloud_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.nextcloud_secret_provider
  ]
}

# HaRP Service
resource "kubernetes_service" "harp" {
  metadata {
    name      = "appapi-harp"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    selector = {
      app = "appapi-harp"
    }

    port {
      name        = "http"
      port        = 8780
      target_port = 8780
    }

    port {
      name        = "frp"
      port        = 8782
      target_port = 8782
    }
  }
}

# Job to configure AppAPI with HaRP daemon
resource "kubernetes_job" "configure_appapi_harp" {
  metadata {
    name      = "configure-appapi-harp-${formatdate("YYYYMMDDhhmmss", timestamp())}"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    backoff_limit = 5

    template {
      metadata {}

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name
        restart_policy       = "OnFailure"

        container {
          name  = "configure"
          image = "nextcloud:latest"

          command = [
            "sh",
            "-c",
            <<-EOT
                        # Wait for Nextcloud to be ready
                        until php occ status 2>/dev/null; do
                          echo "Waiting for Nextcloud to be ready..."
                          sleep 10
                        done

                        echo "Nextcloud is ready, waiting for HaRP service..."

                        # Wait for HaRP to be accessible (using curl)
                        until curl -s --max-time 5 http://appapi-harp:8780/ >/dev/null 2>&1; do
                          echo "Waiting for HaRP service on appapi-harp:8780..."
                          sleep 5
                        done
                        echo "HaRP is accessible, configuring AppAPI..."

                        # Install AppAPI if not already installed
                        php occ app:install app_api || echo "AppAPI already installed or failed"
                        php occ app:enable app_api || echo "AppAPI already enabled"

                        # Unregister existing daemons
                        php occ app_api:daemon:unregister harp_k8s 2>/dev/null || true
                        php occ app_api:daemon:unregister manual_install 2>/dev/null || true

                        # Read the shared key from the mounted CSI volume
                        HARP_KEY=$(cat /mnt/secrets/harp_shared_key)

                        # Register HaRP daemon using HTTPS through nginx

                        php occ app_api:daemon:register \
                          harp_k8s \
                          "HaRP (Kubernetes)" \
                          docker-install \
                          http \
                          "appapi-harp:8780" \
                          "https://${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}" \
                          --net=host \
                          --harp \
                          --harp_frp_address="appapi-harp:8782" \
                          --harp_shared_key="$HARP_KEY" \
                          --set-default

                        echo "AppAPI HaRP daemon registered"
                        php occ app_api:daemon:list

                        echo "Checking if default is set..."
                        php occ config:app:get app_api default_daemon_config

                        echo "Final config:"
                        php occ config:list app_api
                      EOT
          ]


          env {
            name  = "POSTGRES_HOST"
            value = "postgres"
          }

          env {
            name  = "POSTGRES_DB"
            value = "nextcloud"
          }

          env {
            name  = "POSTGRES_USER"
            value = "nextcloud"
          }


          env {
            name  = "REDIS_HOST"
            value = "redis"
          }


          volume_mount {
            name       = "nextcloud-data"
            mount_path = "/var/www/html"
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        volume {
          name = "nextcloud-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.nextcloud_data.metadata[0].name
          }
        }

        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.nextcloud_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment.nextcloud,
    kubernetes_deployment.harp,
    kubernetes_service.harp,
    kubernetes_service.postgres,
    kubernetes_service.redis,
    kubernetes_manifest.nextcloud_secret_provider
  ]

  lifecycle {
    ignore_changes = [
      metadata[0].name
    ]
  }
}


# Tailscale auth secret for Collabora
resource "kubernetes_secret" "collabora_tailscale_auth" {
  metadata {
    name      = "collabora-tailscale-auth"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  type = "Opaque"

  data = {
    TS_AUTHKEY = headscale_pre_auth_key.collabora_server.key
  }
}


# Nginx config for Collabora
resource "kubernetes_config_map" "collabora_nginx_config" {
  metadata {
    name      = "collabora-nginx-config"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  data = {
    "nginx.conf" = <<-EOT
      events {
        worker_connections 1024;
      }
      http {
        upstream collabora {
          server localhost:9980;
        }

        map $http_upgrade $connection_upgrade {
          default upgrade;
          '' close;
        }

        server {
          # Do not use http2 for now as it may cause issues
          listen 443 ssl;
          server_name ${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain};

          # SSL configuration
          ssl_certificate /etc/nginx/certs/tls.crt;
          ssl_certificate_key /etc/nginx/certs/tls.key;
          ssl_protocols TLSv1.2 TLSv1.3;
          ssl_ciphers HIGH:!aNULL:!MD5;
          ssl_prefer_server_ciphers on;

          # Security headers
          add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

          # Collabora-specific settings
          client_max_body_size 0;
          proxy_read_timeout 36000s;

          # static files
          location ^~ /browser {
            proxy_pass http://collabora;
            proxy_set_header Host $http_host;
          }

          # WOPI discovery URL
          location ^~ /hosting/discovery {
            proxy_pass http://collabora;
            proxy_set_header Host $http_host;
          }

          # Capabilities
          location ^~ /hosting/capabilities {
            proxy_pass http://collabora;
            proxy_set_header Host $http_host;
          }

          # Admin Console websocket (most specific first)
             location ^~ /cool/adminws {
               proxy_pass http://collabora;
               proxy_set_header Upgrade $http_upgrade;
               proxy_set_header Connection $connection_upgrade;
               proxy_set_header Host $http_host;
               proxy_set_header X-Forwarded-Host $host;
               proxy_set_header X-Forwarded-Proto $scheme;
               proxy_read_timeout 36000s;
               proxy_http_version 1.1;
             }

             # CRITICAL: ALL /cool/ paths go to Collabora with WebSocket support
             # Collabora handles WebSocket upgrade internally
             location /cool/ {
               proxy_pass http://collabora;
               proxy_set_header Upgrade $http_upgrade;
               proxy_set_header Connection $connection_upgrade;
               proxy_set_header Host $http_host;
               proxy_set_header X-Forwarded-Host $host;
               proxy_set_header X-Forwarded-Proto $scheme;
               proxy_read_timeout 36000s;
               proxy_http_version 1.1;

               # Disable buffering for WebSocket
               proxy_buffering off;
               proxy_request_buffering off;
             }

        }
      }
    EOT
  }
}

# Collabora Deployment
resource "kubernetes_deployment" "collabora" {
  metadata {
    name      = "collabora"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "collabora"
      }
    }

    template {
      metadata {
        labels = {
          app = "collabora"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name
        host_aliases {
          ip = kubernetes_service.nextcloud_internal.spec[0].cluster_ip
          hostnames = [
            "${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          ]
        }
        init_container {
          name  = "wait-for-secrets"
          image = "busybox:latest"

          command = [
            "sh",
            "-c",
            <<-EOT
                    echo 'Waiting for Collabora secrets to sync from Vault...'
                    TIMEOUT=300
                    ELAPSED=0
                    until [ -f /mnt/secrets/collabora_password ]; do
                      if [ $ELAPSED -ge $TIMEOUT ]; then
                        echo "Timeout waiting for secrets after $${TIMEOUT}s"
                        exit 1
                      fi
                      echo "Still waiting... ($${ELAPSED}s)"
                      sleep 5
                      ELAPSED=$((ELAPSED + 5))
                    done
                    echo 'Collabora secrets synced successfully!'
                    ls -la /mnt/secrets/
                  EOT
          ]

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Tailscale sidecar
        container {
          name  = "tailscale"
          image = "tailscale/tailscale:latest"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }

          env {
            name  = "TS_KUBE_SECRET"
            value = "collabora-tailscale-state"
          }

          env {
            name  = "TS_USERSPACE"
            value = "false"
          }

          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.collabora_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }

          env {
            name  = "TS_HOSTNAME"
            value = var.collabora_domain
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

        # Nginx reverse proxy for TLS termination
        container {
          name  = "nginx"
          image = "nginx:alpine"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "collabora-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }

          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }
        }

        # Collabora container
        container {
          name  = "collabora"
          image = "collabora/code:latest"

          env {
            name  = "aliasgroup1"
            value = "https://${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }

          env {
            name  = "server_name"
            value = "${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }



          env {
            name  = "username"
            value = "admin"
          }

          env {
            name = "password"
            value_from {
              secret_key_ref {
                name = "nextcloud-secrets"
                key  = "collabora_password"
              }
            }
          }
          env {
            name = "extra_params"
            # Use .* to allow all hosts temporarily
            value = "--o:ssl.enable=false --o:ssl.termination=true --o:net.proto=https --o:storage.wopi.host=${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain} --o:logging.level=warning"
          }
          env {
            name  = "dictionaries"
            value = "en_US"
          }

          port {
            container_port = 9980
            name           = "http"
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "500m"
              memory = "1Gi"
            }
            limits = {
              cpu    = "2000m"
              memory = "4Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/hosting/discovery"
              port = 9980
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            timeout_seconds       = 10
          }

          readiness_probe {
            http_get {
              path = "/hosting/discovery"
              port = 9980
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        volume {
          name = "collabora-tls"
          secret {
            secret_name = "collabora-tls"
          }
        }

        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.collabora_nginx_config.metadata[0].name
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
              secretProviderClass = kubernetes_manifest.nextcloud_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.nextcloud_secret_provider
  ]
}

# Collabora Service (internal only - accessed via Tailscale)
# Internal service for Nextcloud -> Collabora communication
resource "kubernetes_service" "collabora_internal" {
  metadata {
    name      = "collabora-internal"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    selector = {
      app = "collabora"
    }

    port {
      name        = "https" # Changed from "http"
      port        = 443     # Changed from 9980
      target_port = 443     # Point to nginx's HTTPS port
    }

    type = "ClusterIP"
  }
}


# Job to configure Collabora Office
resource "kubernetes_job" "configure_collabora_on_nextcloud" {
  metadata {
    name      = "configure-collabora-${formatdate("YYYYMMDDhhmmss", timestamp())}"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    backoff_limit = 5

    template {
      metadata {}

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name
        restart_policy       = "OnFailure"

        container {
          name  = "configure"
          image = "nextcloud:latest"

          command = [
            "sh",
            "-c",
            <<-EOT
              # Wait for Nextcloud to be ready
              until php occ status 2>/dev/null; do
                echo "Waiting for Nextcloud to be ready..."
                sleep 10
              done

              echo "Configuring Collabora Office app..."

              # Install Collabora app
              php occ app:install richdocuments || echo "Collabora already installed"
              php occ app:enable richdocuments

              # Configure Collabora with HTTPS URLs
              php occ config:app:set richdocuments wopi_url --value="https://${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
              php occ config:app:set richdocuments public_wopi_url --value="https://${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"

              # Allow Nextcloud to connect to local/internal servers
              php occ config:system:set allow_local_remote_servers --value=true --type=boolean

              # Set system overrides for HTTPS
              php occ config:system:set overwriteprotocol --value=https
              php occ config:system:set overwrite.cli.url --value="https://${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"

              # Add Collabora domain to trusted domains
              php occ config:system:set trusted_domains 2 --value="${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"

              # Set WOPI allowlist with correct format
              php occ config:app:set richdocuments wopi_allowlist --value="127.0.0.1,::1,localhost,${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain},${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain},10.43.0.0/16,10.42.0.0/16"

              # Clear discovery cache and reactivate
              php occ config:app:delete richdocuments discovery || true
              php occ config:app:delete richdocuments discovery_parsed || true
              php occ richdocuments:activate-config

              echo "Collabora configuration completed:"
              php occ config:app:get richdocuments wopi_url
              php occ config:app:get richdocuments public_wopi_url
              php occ config:app:get richdocuments wopi_allowlist
              php occ config:system:get allow_local_remote_servers
              php occ config:system:get trusted_domains
            EOT
          ]

          env {
            name  = "POSTGRES_HOST"
            value = "postgres"
          }

          env {
            name  = "POSTGRES_DB"
            value = "nextcloud"
          }

          env {
            name  = "POSTGRES_USER"
            value = "nextcloud"
          }

          env {
            name  = "REDIS_HOST"
            value = "redis"
          }

          volume_mount {
            name       = "nextcloud-data"
            mount_path = "/var/www/html"
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        volume {
          name = "nextcloud-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.nextcloud_data.metadata[0].name
          }
        }

        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.nextcloud_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment.nextcloud,
    kubernetes_deployment.collabora,
    kubernetes_job.configure_appapi_harp
  ]

  lifecycle {
    ignore_changes = [
      metadata[0].name
    ]
  }
}
