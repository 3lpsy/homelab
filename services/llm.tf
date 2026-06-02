# Local LLM inference — llama-swap + llama.cpp (Vulkan/RADV) on artemis.
#
# Single pod: llama-swap (serves an OpenAI-compatible API on :8080, swapping
# llama-server processes per model on demand — see data/llama-swap/config.yaml)
# + nginx (TLS termination on :443) + tailscale (advertises llm.<hs>.<magic>).
# Replaces the DeepInfra tier in var.llm_models; LiteLLM routes llamaswap-
# provider models here (services/litellm.tf), and the personal user can hit the
# tailnet URL directly for ad-hoc testing.
#
# Auth: none at the app layer for now (llama-swap's `apiKeys` is the future
# hook). Access is gated by the Headscale ACL (group:personal → group:llm-server
# in homelab/modules/tailnet-infra/acls.tf) for tailnet clients and by the
# NetworkPolicy below for in-cluster LiteLLM. The GGUF download + image build
# run as Jobs in services/llm-jobs.tf.
#
# GPU: requests amd.com/gpu=2 (both R9700s, layer-split). The ROCm
# k8s-device-plugin (services/amd-gpu-plugin.tf) injects /dev/kfd +
# /dev/dri/renderD* and sets the cgroup device whitelist — so NO privileged,
# NO manual device host_path mounts. The container runs as root, which opens
# the render nodes regardless of the host `render` GID. If a future non-root
# image can't see the cards (in-pod `vulkaninfo --summary` shows 0/1), add
# `security_context { supplemental_groups = [<render gid from artemis>] }`.

locals {
  llm_fqdn  = "${var.llm_domain}.${local.magic_fqdn_suffix}"
  llm_image = "${local.thunderbolt_registry}/llama-swap:latest"
}

resource "kubernetes_namespace" "llm" {
  metadata {
    name = "llm"
  }
}

resource "kubernetes_service_account" "llm" {
  metadata {
    name      = "llm"
    namespace = kubernetes_namespace.llm.metadata[0].name
  }
  automount_service_account_token = false
}

# Pull-secret for the in-cluster registry (the llama-swap image is a BuildKit
# build pushed by services/llm-jobs.tf).
resource "kubernetes_secret" "llm_registry_pull_secret" {
  metadata {
    name      = "registry-pull-secret"
    namespace = kubernetes_namespace.llm.metadata[0].name
  }
  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${local.thunderbolt_registry}" = {
          username = "internal"
          password = random_password.registry_user_passwords["internal"].result
          auth     = base64encode("internal:${random_password.registry_user_passwords["internal"].result}")
        }
      }
    })
  }
}

# Default-deny baseline. Internet egress stays ON (default): the tailscale
# sidecar needs Headscale/DERP, and the GGUF download Job (same ns) pulls from
# HuggingFace. The only cross-ns ingress allow is litellm → :443 below.
module "llm_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.llm.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

module "llm_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "llm"
  namespace            = kubernetes_namespace.llm.metadata[0].name
  service_account_name = kubernetes_service_account.llm.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.llm_server_user
}

# TLS cert (ACME via infra-tls) + CSI SecretProviderClass. config_secrets is
# empty: llama-swap has no app secrets and no auth yet, so the module syncs
# only the TLS secret. (The module count-gates the config secret on a non-empty
# map — TLS sync is unaffected.)
module "llm_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "llm"
  namespace            = kubernetes_namespace.llm.metadata[0].name
  service_account_name = kubernetes_service_account.llm.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = local.llm_fqdn
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  config_secrets = {}

  providers = { acme = acme }
}

resource "kubernetes_config_map" "llm_config" {
  metadata {
    name      = "llm-config"
    namespace = kubernetes_namespace.llm.metadata[0].name
  }
  data = {
    "config.yaml" = file("${path.module}/../data/llama-swap/config.yaml")
  }
}

resource "kubernetes_config_map" "llm_nginx_config" {
  metadata {
    name      = "llm-nginx-config"
    namespace = kubernetes_namespace.llm.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/llm.nginx.conf.tpl", {
      server_domain       = local.llm_fqdn
      nginx_logging_block = local.nginx_logging_blocks["llm"]
    })
  }
}

# GGUF cache. prevent_destroy: re-downloading the ~30GB headline + coder is
# slow. Populated by the download Job in services/llm-jobs.tf. local-path =
# node-bound to artemis (where the GPU pod is pinned).
resource "kubernetes_persistent_volume_claim" "llm_models" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "llm-models"
    namespace = kubernetes_namespace.llm.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.llm_model_storage_size
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_deployment" "llm" {
  metadata {
    name      = "llm"
    namespace = kubernetes_namespace.llm.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      # Single GPU node, RWO PVC, exclusive VRAM — never run two pods at once.
      type = "Recreate"
    }
    selector {
      match_labels = { app = "llm" }
    }

    template {
      metadata {
        labels = { app = "llm" }
        annotations = {
          "llm-config-hash"                     = sha1(kubernetes_config_map.llm_config.data["config.yaml"])
          "nginx-config-hash"                   = sha1(kubernetes_config_map.llm_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = module.llm_tls_vault.tls_secret_name
        }
      }

      spec {
        service_account_name = kubernetes_service_account.llm.metadata[0].name

        # GPU node: nodeSelector pulls it onto artemis, the toleration clears
        # the gpu=true:NoSchedule taint (docs/CLUSTER.md).
        node_selector = { node = "artemis" }
        toleration {
          key      = "gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        image_pull_secrets {
          name = kubernetes_secret.llm_registry_pull_secret.metadata[0].name
        }

        # Gate nginx on the TLS cert landing in /mnt/secrets (CSI mount) so it
        # doesn't crashloop on missing certs at boot. Mounting the CSI volume
        # here also triggers the Vault→k8s TLS Secret sync that nginx consumes.
        init_container {
          name              = "wait-for-secrets"
          image             = var.image_busybox
          image_pull_policy = "Always"
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

        # llama-swap: serves OpenAI-compatible HTTP on :8080, spawning
        # llama-server per model from the config. Both R9700s via amd.com/gpu=2.
        container {
          name              = "llama-swap"
          image             = local.llm_image
          image_pull_policy = "Always"

          port {
            container_port = 8080
            name           = "llama-swap"
          }

          volume_mount {
            name       = "models"
            mount_path = "/models"
            read_only  = true
          }
          volume_mount {
            name       = "llm-config"
            mount_path = "/etc/llama-swap"
            read_only  = true
          }
          # llama.cpp multi-threaded loaders want more than the 64Mi default.
          volume_mount {
            name       = "dshm"
            mount_path = "/dev/shm"
          }
          # GPU telemetry for llama-swap's Performance Monitor. The host's LACT
          # daemon (lactd on artemis) exposes /run/lactd.sock; llama-swap reads
          # GPU temp/clocks/power/VRAM/util from it directly (its preferred
          # source, cleaner than rocm-smi). We only read — never control the GPU.
          volume_mount {
            name       = "lactd-sock"
            mount_path = "/run/lactd.sock"
          }

          resources {
            requests = {
              "amd.com/gpu" = "2"
              cpu           = "2"
              memory        = "24Gi"
            }
            limits = {
              "amd.com/gpu" = "2"
              cpu           = "8"
              memory        = "48Gi"
            }
          }

          # llama-swap's HTTP listener is up well before any model loads, so a
          # TCP probe is the right readiness signal (don't gate on a model).
          readiness_probe {
            tcp_socket { port = 8080 }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
          liveness_probe {
            tcp_socket { port = 8080 }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 5
          }
        }

        # Nginx: TLS termination on :443 → llama-swap on 127.0.0.1:8080.
        container {
          name              = "nginx"
          image             = var.image_nginx
          image_pull_policy = "Always"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "llm-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        # Tailscale ingress sidecar. Advertises llm.<hs>.<magic> under the
        # `llm` headscale user.
        container {
          name              = "tailscale"
          image             = var.image_tailscale
          image_pull_policy = "Always"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.llm_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.llm_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.llm_domain
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

          volume_mount {
            name       = "dev-net-tun"
            mount_path = "/dev/net/tun"
          }
          volume_mount {
            name       = "tailscale-state"
            mount_path = "/var/lib/tailscale"
          }

          resources {
            requests = { cpu = "20m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "256Mi" }
          }
        }

        # Volumes
        volume {
          name = "models"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.llm_models.metadata[0].name
          }
        }
        volume {
          name = "llm-config"
          config_map {
            name = kubernetes_config_map.llm_config.metadata[0].name
          }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.llm_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "llm-tls"
          secret { secret_name = module.llm_tls_vault.tls_secret_name }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.llm_tls_vault.spc_name
            }
          }
        }
        volume {
          name = "dshm"
          empty_dir {
            medium     = "Memory"
            size_limit = "2Gi"
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
        # Host LACT daemon socket for GPU telemetry (mounted on the llama-swap
        # container above). type=Socket requires the socket to exist, so lactd
        # must be running on artemis before this pod starts — a metrics→inference
        # coupling. Keep lactd enabled at boot (systemctl enable --now lactd); if
        # you don't want the coupling, drop this volume + its mount and the
        # monitor simply runs without GPU telemetry.
        volume {
          name = "lactd-sock"
          host_path {
            path = "/run/lactd.sock"
            type = "Socket"
          }
        }
      }
    }
  }

  depends_on = [
    module.llm_tls_vault,
    module.llm_build,
    kubernetes_job.llm_model_download,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "llm" {
  metadata {
    name      = "llm"
    namespace = kubernetes_namespace.llm.metadata[0].name
  }
  spec {
    selector = { app = "llm" }
    # In-cluster LiteLLM reaches :443 via host_aliases pinning llm.<hs>.<magic>
    # to this ClusterIP; tailnet clients hit the pod's nginx:443 via the TS
    # sidecar (same netns) and don't traverse this Service.
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
  }
}

# Cross-ns ingress: litellm → llm:443. Source-side egress allow lives in
# services/litellm.tf as litellm-to-llm.
resource "kubernetes_network_policy" "llm_from_litellm" {
  metadata {
    name      = "llm-from-litellm"
    namespace = kubernetes_namespace.llm.metadata[0].name
  }
  spec {
    pod_selector { match_labels = { app = "llm" } }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.litellm.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "litellm" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}
