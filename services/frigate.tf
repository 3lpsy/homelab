resource "kubernetes_namespace" "frigate" {
  metadata {
    name = "frigate"
  }
}

# Per-cam derived form: env_key is the sanitized uppercase token used as
# the suffix of FRIGATE_RTSP_PASSWORD_* (Frigate's `{FRIGATE_*}` config
# substitution requires a static identifier, so we precompute it here).
locals {
  frigate_cams = {
    for name, cam in var.frigate_cameras : name => merge(cam, {
      env_key = upper(replace(name, "/[^a-zA-Z0-9]/", "_"))
    })
  }
  frigate_cam_passwords = {
    for name, cam in var.frigate_cameras : "rtsp_password_${name}" => cam.password
  }
}

resource "kubernetes_service_account" "frigate" {
  metadata {
    name      = "frigate"
    namespace = kubernetes_namespace.frigate.metadata[0].name
  }
  automount_service_account_token = false
}

# Pull-secret for the in-cluster registry; only the seed-model init
# container needs it (frigate-model image lives in the local registry).
# Frigate itself, nginx, tailscale, busybox all pull from public registries
# / pull-through caches and don't need this credential.
resource "kubernetes_secret" "frigate_registry_pull_secret" {
  metadata {
    name      = "registry-pull-secret"
    namespace = kubernetes_namespace.frigate.metadata[0].name
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

# Vault-tracked admin password for Frigate's built-in auth. Terraform is
# the source of truth — `random_password.frigate_admin` -> Vault -> CSI
# -> synced k8s secret -> seed-admin-user init -> /config/frigate.db.
#
# Retrieval:
#   vault kv get -field=admin_password secret/frigate/config
#
# Rotation:
#   ./terraform.sh services apply -replace=random_password.frigate_admin
#   (Vault picks up the new value, Reloader rolls the pod, the init
#   container upserts the new PBKDF2 hash into Frigate's user table.)
#
# Frigate has no upstream CLI/env hook for password seeding, so the init
# container talks to its SQLite db directly. See seed-admin-user below for
# the schema-aware seeding script. UI password changes are NOT supported —
# they'd be overwritten on the next pod restart.
resource "random_password" "frigate_admin" {
  length  = 32
  special = false
}

module "frigate_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "frigate"
  namespace            = kubernetes_namespace.frigate.metadata[0].name
  service_account_name = kubernetes_service_account.frigate.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.frigate_server_user
}

module "frigate_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "frigate"
  namespace            = kubernetes_namespace.frigate.metadata[0].name
  service_account_name = kubernetes_service_account.frigate.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = "${var.frigate_domain}.${local.magic_fqdn_suffix}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  config_secrets = merge(
    {
      admin_password = random_password.frigate_admin.result
      # Same plaintext as `frigate_password` under homeassist/mosquitto —
      # both keys are written from the single random_password resource in
      # homeassist-mosquitto.tf, so they cannot drift. Mounted here under
      # frigate's own Vault path to avoid granting frigate's vault role
      # read on homeassist/mosquitto.
      mqtt_password = random_password.homeassist_mqtt_frigate.result
    },
    local.frigate_cam_passwords,
  )

  providers = { acme = acme }
}

resource "kubernetes_persistent_volume_claim" "frigate_config" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "frigate-config"
    namespace = kubernetes_namespace.frigate.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.frigate_config_size
      }
    }
  }
  wait_until_bound = false
}

# Recordings + clip exports live here. Sized large because Frigate continuous
# recording fills disk fast; split from `frigate-config` so swapping in a
# network-backed storage class (TrueNAS / democratic-csi) later only touches
# this PVC, not the small config one.
resource "kubernetes_persistent_volume_claim" "frigate_recordings" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "frigate-recordings"
    namespace = kubernetes_namespace.frigate.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.frigate_recordings_size
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_config_map" "frigate_config" {
  metadata {
    name      = "frigate-config"
    namespace = kubernetes_namespace.frigate.metadata[0].name
  }
  data = {
    # Day-1 config: no cameras, AMD VAAPI hwaccel for decode, CPU detector.
    # When cameras land, edit data/frigate/config.yml.tpl in place and
    # re-apply — Reloader rolls the deployment when the ConfigMap hash
    # changes (config-hash pod annotation below).
    "config.yml" = templatefile("${path.module}/../data/frigate/config.yml.tpl", {
      cameras = local.frigate_cams
    })
  }
}

resource "kubernetes_config_map" "frigate_nginx_config" {
  metadata {
    name      = "frigate-nginx-config"
    namespace = kubernetes_namespace.frigate.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/frigate.nginx.conf.tpl", {
      server_domain = "${var.frigate_domain}.${local.magic_fqdn_suffix}"
    })
  }
}

# Single-pod namespace (frigate + nginx + tailscale sidecars in one pod).
# No cross-namespace traffic today. Camera ingress is RTSP/ONVIF over the
# LAN, which doesn't traverse the cluster network.
module "frigate_netpol_baseline" {
  source = "../templates/netpol-baseline"

  namespace    = kubernetes_namespace.frigate.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

resource "kubernetes_deployment" "frigate" {
  metadata {
    name      = "frigate"
    namespace = kubernetes_namespace.frigate.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "frigate" }
    }

    template {
      metadata {
        labels = { app = "frigate" }
        annotations = {
          "config-hash"                         = sha1(kubernetes_config_map.frigate_config.data["config.yml"])
          "nginx-config-hash"                   = sha1(kubernetes_config_map.frigate_nginx_config.data["nginx.conf"])
          # Roll the pod when the model-builder Dockerfile changes; the
          # image tag stays `:latest`, so kubelet won't otherwise notice
          # a fresh build of frigate-model. The seed-model init container
          # copies /model.onnx out of that image on every restart.
          "model-image-hash" = sha1(file("${path.module}/../data/images/frigate-model/Dockerfile"))
          "secret.reloader.stakater.com/reload" = "${module.frigate_tls_vault.tls_secret_name},${module.frigate_tls_vault.config_secret_name}"
          # Recordings are large + ephemeral by design; events DB is rebuilt on
          # restore as cameras start producing new footage. Excluded from FSB.
          "backup.velero.io/backup-volumes-excludes" = "frigate-recordings,frigate-config"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.frigate.metadata[0].name

        image_pull_secrets {
          name = kubernetes_secret.frigate_registry_pull_secret.metadata[0].name
        }

        # Host is Fedora: video=39, render=105 (mode 0666 on renderD128 means
        # render membership isn't strictly required, but harmless). card0 is
        # 0660 root:video — VAAPI only touches renderD128 so video membership
        # is also not strictly required, kept defensively. Re-check GIDs if
        # the node is reprovisioned to a different distro.
        security_context {
          supplemental_groups = [39, 105]
          fs_group            = 1000
        }

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "admin_password"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Copies the YOLOv9-tiny ONNX artifact baked into the
        # frigate-model image into /config/model_cache/. Frigate's ONNX
        # detector requires an explicit model.path and ships no default;
        # the model-builder Job (frigate-jobs.tf) runs once via BuildKit
        # to produce this artifact image. Re-runs on every pod start are
        # cheap (image is alpine + ~10MB ONNX, fully cached after first
        # pull) and idempotent — `cp -f` always lands the latest version.
        init_container {
          name    = "seed-model"
          image   = local.frigate_model_image
          command = ["sh", "-c", "mkdir -p /config/model_cache && cp -f /model.onnx /config/model_cache/yolo.onnx"]
          volume_mount {
            name       = "frigate-config"
            mount_path = "/config"
          }
        }

        # Seeds Frigate's auth db with the Vault-managed admin password
        # before the main container starts. Script body lives at
        # data/frigate/seed-admin.py — see that file for the schema-aware
        # upsert + PBKDF2 hash details.
        init_container {
          name  = "seed-admin-user"
          image = var.image_frigate
          command = [
            "python3", "-c", file("${path.module}/../data/frigate/seed-admin.py")
          ]
          volume_mount {
            name       = "frigate-config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Frigate
        container {
          name  = "frigate"
          image = var.image_frigate

          # Without privileged the container's cgroup device whitelist
          # blocks open() on /dev/dri/renderD128 and /dev/kfd even though
          # the files are visible (filesystem perms via supplemental_groups
          # are necessary but not sufficient — k8s separately gates *use*
          # of host devices). Symptom: ffmpeg "No VA display found" and
          # Frigate's radeon stats poller "Operation not permitted".
          # Proper fix is the AMD GPU device plugin; privileged is the
          # one-liner workaround for single-node homelab.
          security_context {
            privileged = true
          }

          port {
            container_port = 8971
            name           = "https-auth"
          }

          env {
            name  = "TZ"
            value = var.homeassist_time_zone
          }

          # ROCm targets gfx1030 by default; Rembrandt 680M reports gfx1035
          # which is not in AMD's official support matrix. The override tells
          # the HSA runtime to treat the iGPU as gfx1030, which is the
          # well-known workaround that gets ROCm working on Rembrandt APUs.
          # If you swap delphi for hardware with a properly-supported GPU
          # (RDNA2/3 discrete), this can be removed.
          env {
            name  = "HSA_OVERRIDE_GFX_VERSION"
            value = "10.3.0"
          }

          # Force AMD's mesa VA-API driver. The rocm image bundles
          # mesa-va-drivers (radeonsi), but ffmpeg's autoprobe sometimes
          # picks the Intel iHD driver path first and fails with
          # "No VA display found for /dev/dri/renderD128".
          env {
            name  = "LIBVA_DRIVER_NAME"
            value = "radeonsi"
          }

          # Per-cam RTSP password env vars; referenced from config.yml as
          # `{FRIGATE_RTSP_PASSWORD_<KEY>}`. Sourced from the Vault-synced
          # config Secret so the rendered ConfigMap stays plaintext-clean
          # (only the username + IP are inlined in URLs).
          dynamic "env" {
            for_each = local.frigate_cams
            content {
              name = "FRIGATE_RTSP_PASSWORD_${env.value.env_key}"
              value_from {
                secret_key_ref {
                  name = module.frigate_tls_vault.config_secret_name
                  key  = "rtsp_password_${env.key}"
                }
              }
            }
          }

          # MQTT broker creds for the `frigate` user on Mosquitto in the
          # homeassist namespace. Referenced from config.yml as
          # `{FRIGATE_MQTT_PASSWORD}`.
          env {
            name = "FRIGATE_MQTT_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.frigate_tls_vault.config_secret_name
                key  = "mqtt_password"
              }
            }
          }

          # Frigate ffmpeg uses /dev/shm for inter-process frame buffers.
          # The container default (64Mi) is too small for anything past one
          # camera; bump via a Memory-backed emptyDir.
          volume_mount {
            name       = "dshm"
            mount_path = "/dev/shm"
          }
          volume_mount {
            name       = "frigate-config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "frigate-recordings"
            mount_path = "/media/frigate"
          }
          volume_mount {
            name       = "frigate-config-file"
            mount_path = "/config/config.yml"
            sub_path   = "config.yml"
          }
          # AMD VAAPI render node passthrough for ffmpeg hwaccel decode.
          # The whole /dev/dri dir is mounted because ffmpeg probes both
          # card0 and renderD128 during VAAPI init.
          volume_mount {
            name       = "dri"
            mount_path = "/dev/dri"
          }
          # ROCm compute device. /dev/dri/renderD128 alone is not enough —
          # the HSA runtime opens /dev/kfd to enqueue compute kernels.
          volume_mount {
            name       = "kfd"
            mount_path = "/dev/kfd"
          }
          # Pins the CSI secrets-store volume so the synced `frigate-tls`
          # k8s secret stays alive for the nginx sidecar; Frigate itself
          # never reads from this path.
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "500m", memory = "1Gi" }
            limits   = { cpu = "4000m", memory = "4Gi" }
          }

          # ROCm init + first-run YOLO-NAS model download into the config
          # PVC takes 1-3 minutes; probes need to allow that without the
          # kubelet flapping the pod.
          liveness_probe {
            tcp_socket {
              port = 8971
            }
            initial_delay_seconds = 180
            period_seconds        = 30
            timeout_seconds       = 10
            failure_threshold     = 5
          }

          readiness_probe {
            tcp_socket {
              port = 8971
            }
            initial_delay_seconds = 120
            period_seconds        = 10
          }
        }

        # Frigate Volumes
        volume {
          name = "frigate-config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.frigate_config.metadata[0].name
          }
        }
        volume {
          name = "frigate-recordings"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.frigate_recordings.metadata[0].name
          }
        }
        volume {
          name = "frigate-config-file"
          config_map {
            name = kubernetes_config_map.frigate_config.metadata[0].name
          }
        }
        volume {
          name = "dshm"
          empty_dir {
            medium     = "Memory"
            size_limit = "512Mi"
          }
        }
        volume {
          name = "dri"
          host_path {
            path = "/dev/dri"
            type = "Directory"
          }
        }
        volume {
          name = "kfd"
          host_path {
            path = "/dev/kfd"
            type = "CharDevice"
          }
        }

        # Nginx
        container {
          name  = "frigate-nginx"
          image = var.image_nginx

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "frigate-tls"
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

        # Nginx Volumes
        volume {
          name = "frigate-tls"
          secret { secret_name = module.frigate_tls_vault.tls_secret_name }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.frigate_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.frigate_tls_vault.spc_name
            }
          }
        }

        # Tailscale
        container {
          name  = "frigate-tailscale"
          image = var.image_tailscale

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.frigate_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.frigate_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.frigate_domain
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
    module.frigate_tls_vault,
    # Block deployment until the model image exists in the registry —
    # otherwise the seed-model init container ImagePullBackoffs on first
    # apply.
    module.frigate_model_build,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}
