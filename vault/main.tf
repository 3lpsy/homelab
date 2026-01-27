terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }

    # The provider is declared here just like any provider...
    acme = {
      source  = "vancluever/acme"
      version = "~> 2.0"
    }

    headscale = {
      source  = "awlsring/headscale"
      version = "~> 0.4.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }
}

provider "acme" {
  server_url = var.acme_server_url
}


provider "kubernetes" {
  config_path = pathexpand("/home/vanguard/.config/kube/config")
}

provider "headscale" {
  endpoint = "https://${data.terraform_remote_state.homelab.outputs.headscale_server_fqdn}"
  api_key  = var.headscale_api_key
}

provider "helm" {
  kubernetes {
    config_path = pathexpand("/home/vanguard/.config/kube/config")
  }
}

data "terraform_remote_state" "homelab" {
  backend = "local"

  config = {
    path = "../homelab/terraform.tfstate"
  }
}


resource "headscale_pre_auth_key" "vault_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.vault_server
  reusable       = true
  time_to_expire = "1y"
}


module "vault-infra-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.vault_server_host_name}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  # depends_on = [module.nomad-provision-server]
  providers = {
    acme = acme
  }
}

resource "kubernetes_namespace" "vault" {
  metadata {
    name = "vault"

    labels = {
      name = "vault"
    }


  }
}


resource "kubernetes_secret" "tailscale_auth" {
  metadata {
    name      = "tailscale-auth"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  type = "Opaque"

  data = {
    TS_AUTHKEY = headscale_pre_auth_key.vault_server.key
  }
  wait_for_service_account_token = false # import artifact
}

resource "kubernetes_service_account" "vault" {
  metadata {
    name      = "vault"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_role" "tailscale" {
  metadata {
    name      = "tailscale"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["create"]
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "tailscale" {
  metadata {
    name      = "tailscale"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.vault.metadata[0].name
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
}

resource "kubernetes_config_map" "vault_config" {
  metadata {
    name      = "vault-config"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  data = {
    "vault.hcl" = <<-EOT
      ui = true

      # Internal listener for in-cluster communication (no TLS)
      listener "tcp" {
        address = "0.0.0.0:8200"
        cluster_address = "127.0.0.1:9200"
        tls_disable = 1
      }

      # External listener for Tailscale access (with TLS)
      listener "tcp" {
        address = "0.0.0.0:8201"
        tls_disable = 0
        cluster_address = "127.0.0.1:9201"
        tls_cert_file = "/vault/tls/tls.crt"
        tls_key_file = "/vault/tls/tls.key"
      }

      storage "file" {
        path = "/vault/data"
      }

      disable_mlock = true
    EOT
  }
}

resource "kubernetes_secret" "vault_tls" {
  metadata {
    name      = "vault-tls"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = module.vault-infra-tls.fullchain_pem
    "tls.key" = module.vault-infra-tls.privkey_pem
  }
}

resource "kubernetes_persistent_volume_claim" "vault_data" {
  metadata {
    name      = "vault-data"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"

    resources {
      requests = {
        storage = "2Gi"
      }
    }
  }
  wait_until_bound = false
  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_stateful_set" "vault" {
  metadata {
    name      = "vault"
    namespace = kubernetes_namespace.vault.metadata[0].name
    labels = {
      app = "vault"
    }
  }
  timeouts {
    create = "1m"
    update = "1m"
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
      }

      spec {
        service_account_name = kubernetes_service_account.vault.metadata[0].name

        # Init container for permissions
        init_container {
          name  = "init-permissions"
          image = "busybox:latest"
          command = [
            "sh",
            "-c",
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

        # Tailscale sidecar container
        container {
          name  = "tailscale"
          image = "tailscale/tailscale:latest"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }

          # And add this volume mount:
          volume_mount {
            name       = "tailscale-state"
            mount_path = "/var/lib/tailscale"
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
        }

        # Vault container
        container {
          name  = "vault"
          image = "hashicorp/vault:1.18" # or :latest
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

          # Non failing error

          command = ["vault"]
          args = [
            "server",
            "-config=/vault/config/vault.hcl"
          ]

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
            initial_delay_seconds = 60
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

        volume {
          name = "tailscale-state"
          empty_dir {}
        }

        # Volumes
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

        volume {
          name = "dev-net-tun"
          host_path {
            path = "/dev/net/tun"
            type = "CharDevice"
          }
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


resource "kubernetes_network_policy" "vault" {
  depends_on = [kubernetes_stateful_set.vault]

  metadata {
    name      = "vault-network-policy"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "vault"
      }
    }

    policy_types = ["Ingress", "Egress"]

    # Allow from vault-csi namespace (where CSI provider runs)
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "vault-csi"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "8200"
      }
    }

    # Allow internal vault namespace communication
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "vault"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "8200"
      }
    }

    # Allow all egress initially - you can restrict later if needed
    egress {}
  }
}
# resource "kubernetes_network_policy" "vault" {
#   depends_on = [kubernetes_stateful_set.vault]

#   metadata {
#     name      = "vault-network-policy"
#     namespace = kubernetes_namespace.vault.metadata[0].name
#   }

#   spec {
#     pod_selector {
#       match_labels = {
#         app = "vault"
#       }
#     }

#     policy_types = ["Ingress", "Egress"]

# ingress {
#   # Allow from CSI driver pods (they run in kube-system)
#   from {
#     namespace_selector {
#       match_labels = {
#         "kubernetes.io/metadata.name" = "kube-system"
#       }
#     }
#     pod_selector {
#       match_labels = {
#         "app.kubernetes.io/name" = "vault-csi-provider"
#       }
#     }
#   }
#   ports {
#     protocol = "TCP"
#     port     = "8200"
#   }
# }
#     ingress {
#       from {
#         namespace_selector {
#           match_labels = {
#             "kubernetes.io/metadata.name" = "vault"
#           }
#         }
#       }
#       ports {
#         protocol = "TCP"
#         port     = "8200"
#       }
#     }
#     ingress {
#       # Allow from Vault CSI provider (it runs in vault-csi namespace)
#       from {
#         namespace_selector {
#           match_labels = {
#             "kubernetes.io/metadata.name" = "vault-csi"
#           }
#         }
#       }
#       ports {
#         protocol = "TCP"
#         port     = "8200"
#       }
#     }

#     # Egress for Tailscale and K8s API
#     egress {
#       ports {
#         protocol = "UDP"
#         port     = "53" # DNS
#       }
#     }

#     egress {
#       ports {
#         protocol = "TCP"
#         port     = "443" # Tailscale/headscale
#       }
#     }

#     egress {
#       ports {
#         protocol = "TCP"
#         port     = "6443" # K8s API
#       }
#     }
#   }
# }

# Install Secrets Store CSI Driver
resource "helm_release" "secrets_store_csi_driver" {
  name       = "csi-secrets-store"
  repository = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
  chart      = "secrets-store-csi-driver"
  namespace  = "kube-system"

  set {
    name  = "syncSecret.enabled"
    value = "true"
  }
}


# Install Vault CSI Provider (from Vault helm chart)
resource "helm_release" "vault_csi_provider" {
  name             = "vault-csi"
  repository       = "https://helm.releases.hashicorp.com"
  chart            = "vault"
  namespace        = "vault-csi"
  create_namespace = true

  set {
    name  = "server.enabled"
    value = "false"
  }

  set {
    name  = "injector.enabled"
    value = "false"
  }

  set {
    name  = "csi.enabled"
    value = "true"
  }

  set {
    name  = "csi.daemonSet.providersDir"
    value = "/etc/kubernetes/secrets-store-csi-providers"
  }

  depends_on = [
    helm_release.secrets_store_csi_driver,
    kubernetes_namespace.vault
  ]
}


# These resources allow Vault to validate service account tokens from other pods
#
# When the CSI driver tries to authenticate:
# 1. CSI reads the pod's service account token
# 2. CSI sends token to Vault's /v1/auth/kubernetes/login endpoint
# 3. Vault needs to validate this token by calling the Kubernetes TokenReview API
# 4. The vault service account needs permission to create TokenReviews
#
# Without these permissions, authentication fails with "403 permission denied"
resource "kubernetes_cluster_role" "vault_token_reviewer" {
  metadata {
    name = "vault-token-reviewer"
  }

  rule {
    api_groups = ["authentication.k8s.io"]
    resources  = ["tokenreviews"]
    verbs      = ["create"]
  }

  rule {
    api_groups = ["authorization.k8s.io"]
    resources  = ["subjectaccessreviews"]
    verbs      = ["create"]
  }
}

resource "kubernetes_cluster_role_binding" "vault_token_reviewer" {
  metadata {
    name = "vault-token-reviewer-binding"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.vault_token_reviewer.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.vault.metadata[0].name
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
}
