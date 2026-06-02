# Collabora lives in its own `collabora` namespace. Cross-ns WOPI traffic
# to/from nextcloud uses host_aliases pinning the peer FQDN to the peer's
# *-internal ClusterIP, so SNI matches the cert without traversing the
# Tailscale sidecar.

resource "kubernetes_namespace" "collabora" {
  metadata {
    name = "collabora"
  }
}

resource "kubernetes_service_account" "collabora" {
  metadata {
    name      = "collabora"
    namespace = kubernetes_namespace.collabora.metadata[0].name
  }
  automount_service_account_token = false
}

resource "random_password" "collabora_password" {
  length  = 32
  special = false
}

module "collabora_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "collabora"
  namespace            = kubernetes_namespace.collabora.metadata[0].name
  service_account_name = kubernetes_service_account.collabora.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.collabora_server_user

  # Preserve the bare `tailscale` Role name from the pre-module shape so
  # the in-place state rename via moved{} doesn't force RBAC destroy/create.
  role_name = "tailscale"

  # Preserve the existing 1y key TTL. The 3y default applies on rotation.
  time_to_expire = "1y"
}

module "collabora_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "collabora"
  namespace            = kubernetes_namespace.collabora.metadata[0].name
  service_account_name = kubernetes_service_account.collabora.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = "${var.collabora_domain}.${local.magic_fqdn_suffix}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  config_secrets = {
    password = random_password.collabora_password.result
  }

  providers = { acme = acme }
}

resource "kubernetes_config_map" "collabora_nginx_config" {
  metadata {
    name      = "collabora-nginx-config"
    namespace = kubernetes_namespace.collabora.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/collabora.nginx.conf.tpl", {
      server_domain       = "${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
      nginx_logging_block = local.nginx_logging_blocks["collabora"]
    })
  }
}

resource "kubernetes_deployment" "collabora" {
  metadata {
    name      = "collabora"
    namespace = kubernetes_namespace.collabora.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
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
        annotations = {
          "nginx-config-hash"                   = sha1(kubernetes_config_map.collabora_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "collabora-tls"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.collabora.metadata[0].name
        host_aliases {
          ip = kubernetes_service.nextcloud_internal.spec[0].cluster_ip
          hostnames = [
            "${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          ]
        }

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "password"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        init_container {
          name  = "fix-systemplate"
          image = var.image_collabora
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            "cp /opt/cool/systemplate/etc/* /mnt/systemplate-etc/ 2>/dev/null; cp /etc/passwd /etc/group /etc/hosts /etc/host.conf /etc/resolv.conf /mnt/systemplate-etc/ 2>/dev/null; echo 'Systemplate etc updated'"
          ]
          volume_mount {
            name       = "systemplate-etc"
            mount_path = "/mnt/systemplate-etc"
          }
        }

        # Collabora
        container {
          name  = "collabora"
          image = var.image_collabora
          image_pull_policy = "Always"

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
                name = module.collabora_tls_vault.config_secret_name
                key  = "password"
              }
            }
          }

          env {
            name  = "extra_params"
            value = "--o:ssl.enable=false --o:ssl.termination=true --o:net.proto=https --o:storage.wopi.host=${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain} --o:logging.level=warning --o:language=en-US"
          }

          env {
            name  = "dictionaries"
            value = "en_US"
          }

          env {
            name  = "LC_CTYPE"
            value = "en_US.UTF-8"
          }

          env {
            name  = "LC_ALL"
            value = "en_US.UTF-8"
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

          volume_mount {
            name       = "systemplate-etc"
            mount_path = "/opt/cool/systemplate/etc"
          }

          resources {
            requests = {
              cpu    = "1000m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "4000m"
              memory = "4Gi"
            }
          }

          security_context {
            capabilities {
              add = ["SYS_CHROOT", "SYS_ADMIN", "FOWNER", "CHOWN"]
            }
          }

          # tcpSocket instead of httpGet — collabora treats kube-probe's
          # connection close on a websocket-capable endpoint as an ERR
          # (ECONNRESET + EPIPE pair every probe), spamming logs. tcpSocket
          # only checks the port is accepting connections, which is enough
          # signal for liveness and doesn't trigger websocket handshake.
          liveness_probe {
            tcp_socket {
              port = 9980
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 10
          }

          readiness_probe {
            tcp_socket {
              port = 9980
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        # Collabora Volumes
        volume {
          name = "systemplate-etc"
          empty_dir {}
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.collabora_tls_vault.spc_name
            }
          }
        }

        # Nginx
        container {
          name  = "collabora-nginx"
          image = var.image_nginx
          image_pull_policy = "Always"

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

        # Nginx Volumes
        volume {
          name = "collabora-tls"
          secret {
            secret_name = module.collabora_tls_vault.tls_secret_name
          }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.collabora_nginx_config.metadata[0].name
          }
        }

        # Tailscale
        container {
          name  = "collabora-tailscale"
          image = var.image_tailscale
          image_pull_policy = "Always"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }

          env {
            name  = "TS_KUBE_SECRET"
            value = module.collabora_tailscale.state_secret_name
          }

          env {
            name  = "TS_USERSPACE"
            value = "false"
          }

          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.collabora_tailscale.auth_secret_name
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
            requests = {
              cpu    = "20m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
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

  depends_on = [
    module.collabora_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "collabora_internal" {
  metadata {
    name      = "collabora-internal"
    namespace = kubernetes_namespace.collabora.metadata[0].name
  }

  spec {
    selector = {
      app = "collabora"
    }

    port {
      name        = "https"
      port        = 443
      target_port = 443
    }

    type = "ClusterIP"
  }
}

# NetworkPolicies for the `collabora` namespace.
#
# Cross-ns WOPI loop with nextcloud:
#   - nextcloud → collabora-nginx:443 (loading the editor)
#   - collabora → nextcloud-nginx:443 (WOPI callbacks fetching/saving the file)
#
# Both directions ride host_aliases pinning the peer FQDN to the peer's
# *-internal ClusterIP so SNI matches the public cert without going through
# either pod's Tailscale sidecar. Vault egress is not needed at the workload
# level — secrets-store-csi performs the fetch from the vault-csi namespace.

module "collabora_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.collabora.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
  # Internet + kube-api egress on (defaults). Tailscale sidecar needs both.
}

# Ingress on collabora-nginx:443 from the nextcloud pod only.
resource "kubernetes_network_policy" "collabora_from_nextcloud" {
  metadata {
    name      = "collabora-from-nextcloud"
    namespace = kubernetes_namespace.collabora.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "collabora"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.nextcloud.metadata[0].name
          }
        }
        pod_selector {
          match_labels = {
            app = "nextcloud"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

# Egress from the collabora pod to nextcloud-nginx:443 (WOPI callbacks).
resource "kubernetes_network_policy" "collabora_to_nextcloud" {
  metadata {
    name      = "collabora-to-nextcloud"
    namespace = kubernetes_namespace.collabora.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "collabora"
      }
    }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.nextcloud.metadata[0].name
          }
        }
        pod_selector {
          match_labels = {
            app = "nextcloud"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}
