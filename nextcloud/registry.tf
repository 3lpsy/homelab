resource "kubernetes_namespace" "registry" {
  metadata {
    name = "registry"
  }
}

# Service Account & RBAC

resource "kubernetes_service_account" "registry" {
  metadata {
    name      = "registry"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_role" "registry_tailscale" {
  metadata {
    name      = "registry-tailscale"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["create"]
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["registry-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "registry_tailscale" {
  metadata {
    name      = "registry-tailscale"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.registry_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.registry.metadata[0].name
    namespace = kubernetes_namespace.registry.metadata[0].name
  }
}

# Headscale

resource "headscale_pre_auth_key" "registry_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.registry
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "registry_tailscale_auth" {
  metadata {
    name      = "registry-tailscale-auth"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.registry_server.key
  }
}

# TLS

module "registry-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.registry_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

# Creds

resource "random_password" "registry_user_passwords" {
  for_each = toset(var.registry_users)
  length   = 32
  special  = false
}

# Vault

# Plaintext credentials — look these up in Vault when you need to docker login
resource "vault_kv_secret_v2" "registry_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "registry/config"
  data_json = jsonencode({
    users = {
      for user in var.registry_users :
      user => random_password.registry_user_passwords[user].result
    }
  })
}

# Pre-built htpasswd file with bcrypt hashes
resource "vault_kv_secret_v2" "registry_htpasswd" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "registry/htpasswd"
  data_json = jsonencode({
    htpasswd = join("\n", [
      for user in var.registry_users :
      "${user}:${bcrypt(random_password.registry_user_passwords[user].result)}"
    ])
  })

  # bcrypt() generates a new salt every plan, causing perpetual diff.
  # The hashes are functionally equivalent so we suppress the churn.
  # Adding/removing users in var.registry_users still triggers a real
  # update because the random_password resources change.
  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "vault_kv_secret_v2" "registry_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "registry/tls"
  data_json = jsonencode({
    fullchain_pem = module.registry-tls.fullchain_pem
    privkey_pem   = module.registry-tls.privkey_pem
  })
}

# Vault & Role Policy

resource "vault_policy" "registry" {
  name = "registry-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/registry/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "registry" {
  backend                          = "kubernetes"
  role_name                        = "registry"
  bound_service_account_names      = ["registry"]
  bound_service_account_namespaces = ["registry"]
  token_policies                   = [vault_policy.registry.name]
  token_ttl                        = 86400
}

# --- SecretProviderClass (Vault CSI) ----------------------------------------

resource "kubernetes_manifest" "registry_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-registry"
      namespace = kubernetes_namespace.registry.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "registry-htpasswd"
          type       = "Opaque"
          data = [
            {
              objectName = "htpasswd"
              key        = "htpasswd"
            }
          ]
        },
        {
          secretName = "registry-tls"
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
        roleName     = "registry"
        objects = yamlencode([
          {
            objectName = "htpasswd"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/registry/htpasswd"
            secretKey  = "htpasswd"
          },
          {
            objectName = "tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/registry/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/registry/tls"
            secretKey  = "privkey_pem"
          }
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.registry,
    vault_kubernetes_auth_backend_role.registry,
    vault_kv_secret_v2.registry_config,
    vault_kv_secret_v2.registry_htpasswd,
    vault_kv_secret_v2.registry_tls,
    vault_policy.registry
  ]
}

# --- Nginx Config ------------------------------------------------------------

resource "kubernetes_config_map" "registry_nginx_config" {
  metadata {
    name      = "registry-nginx-config"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }
  data = {
    "nginx.conf" = <<-EOT
      events {
        worker_connections 1024;
      }
      http {
        upstream registry {
          server localhost:5000;
        }

        # Required for large image layer uploads
        client_max_body_size 0;
        chunked_transfer_encoding on;

        server {
          listen 443 ssl;
          server_name ${var.registry_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain};

          ssl_certificate     /etc/nginx/certs/tls.crt;
          ssl_certificate_key /etc/nginx/certs/tls.key;
          ssl_protocols       TLSv1.2 TLSv1.3;
          ssl_ciphers         HIGH:!aNULL:!MD5;
          ssl_prefer_server_ciphers on;

          add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

          location /v2/ {
            client_max_body_size 0;

            proxy_pass http://registry;
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            auth_basic           "Docker Registry";
            auth_basic_user_file /etc/nginx/htpasswd;
          }

          location = / {
            return 301 /v2/;
          }
        }
      }
    EOT
  }
}

# PVC

resource "kubernetes_persistent_volume_claim" "registry_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "registry-data"
    namespace = kubernetes_namespace.registry.metadata[0].name
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

# Deployment

resource "kubernetes_deployment" "registry" {
  metadata {
    name      = "registry"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "registry" }
    }

    template {
      metadata {
        labels = { app = "registry" }
      }

      spec {
        service_account_name = kubernetes_service_account.registry.metadata[0].name

        # Wait for Vault CSI secrets to sync
        init_container {
          name  = "wait-for-secrets"
          image = "busybox:latest"
          command = [
            "sh", "-c",
            <<-EOT
              echo 'Waiting for registry secrets to sync from Vault...'
              TIMEOUT=300
              ELAPSED=0
              until [ -f /mnt/secrets/htpasswd ]; do
                if [ $ELAPSED -ge $TIMEOUT ]; then
                  echo "Timeout waiting for secrets after $${TIMEOUT}s"
                  exit 1
                fi
                echo "Still waiting... ($${ELAPSED}s)"
                sleep 5
                ELAPSED=$((ELAPSED + 5))
              done
              echo 'Registry secrets synced successfully!'
            EOT
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
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
            value = "registry-tailscale-state"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.registry_tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.registry_domain
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

        # Nginx TLS + Auth
        container {
          name  = "nginx"
          image = "nginx:alpine"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "registry-tls"
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

        # Registry
        container {
          name  = "registry"
          image = "registry:2"

          port {
            container_port = 5000
            name           = "http"
          }

          env {
            name  = "REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY"
            value = "/var/lib/registry"
          }
          env {
            name  = "REGISTRY_HTTP_ADDR"
            value = "0.0.0.0:5000"
          }
          env {
            name  = "REGISTRY_STORAGE_DELETE_ENABLED"
            value = "true"
          }

          volume_mount {
            name       = "registry-data"
            mount_path = "/var/lib/registry"
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

        # Volumes
        volume {
          name = "registry-tls"
          secret { secret_name = "registry-tls" }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.registry_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "nginx-htpasswd"
          secret { secret_name = "registry-htpasswd" }
        }
        volume {
          name = "registry-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.registry_data.metadata[0].name
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
              secretProviderClass = kubernetes_manifest.registry_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.registry_secret_provider
  ]
}

# Internal Service

resource "kubernetes_service" "registry_internal" {
  metadata {
    name      = "registry-internal"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }
  spec {
    selector = { app = "registry" }
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
    type = "ClusterIP"
  }
}
