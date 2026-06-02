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

  # RP-initiated logout chain. Frigate's UI logout button goes to
  # `proxy.logout_url`; we point it at oauth2-proxy's /sign_out, which
  # clears the local cookie, then redirects (`rd=`) to Zitadel's
  # /oidc/v1/end_session, which terminates the SSO session, then
  # redirects back to https://frigate.<magic>/. Without this chain,
  # logging out of Frigate is a no-op from the user's POV: SSO instantly
  # re-issues a token on the next request.
  frigate_zitadel_end_session_url = "https://${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}/oidc/v1/end_session?post_logout_redirect_uri=${urlencode("https://${var.frigate_domain}.${local.magic_fqdn_suffix}/")}"
  frigate_logout_url              = "/oauth2/sign_out?rd=${urlencode(local.frigate_zitadel_end_session_url)}"
}

resource "kubernetes_service_account" "frigate" {
  metadata {
    name      = "frigate"
    namespace = kubernetes_namespace.frigate.metadata[0].name
  }
  automount_service_account_token = false
}

# Pull secret for the in-cluster registry — the `seed-model` init container
# pulls frigate-model:latest from it. Frigate's other images (ghcr frigate,
# nginx, oauth2-proxy, tailscale) are public, so this pod never needed one
# before the GPU/model cutover. Mirrors the opencode/homeassist/jellyfin
# pattern (internal registry user).
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

# Cookie key for the oauth2-proxy sidecar. oauth2-proxy expects a 16/24/32
# byte secret; 32 alphanumeric chars satisfies the 32-byte case and avoids
# URL-encoding edge cases that special chars would introduce when the
# value is exposed via the OAUTH2_PROXY_COOKIE_SECRET env var.
#
# Rotation forces every signed-in user to re-authenticate (existing
# session cookies become unverifiable):
#   ./terraform.sh services apply -replace=random_password.frigate_oauth2_cookie
resource "random_password" "frigate_oauth2_cookie" {
  length  = 32
  special = false
}

# ─── Zitadel project + roles + OIDC application + per-user grants ────────────
#
# Per memory `feedback_zitadel_one_project_per_service`, each service onboarded
# to Zitadel SSO declares its own project. project_role_check=true so Zitadel
# itself rejects token issuance for users without a grant — no loose-Grafana
# pattern here (memory `project_grafana_oidc_authz_pending`).
resource "zitadel_project" "frigate" {
  name   = "frigate"
  org_id = data.zitadel_organizations.homelab.ids[0]

  project_role_assertion   = true
  project_role_check       = true
  has_project_check        = true
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"
}

# Two project roles drive Frigate's role_map (data/frigate/config.yml.tpl).
# Zitadel emits the granted role keys in the `urn:zitadel:iam:org:project:roles`
# id_token claim; oauth2-proxy reads that claim into X-Forwarded-Groups; nginx
# forwards it to Frigate; Frigate's role_map admin -> [admin], viewer -> [viewer]
# resolves the final role.
resource "zitadel_project_role" "frigate_admin" {
  org_id       = data.zitadel_organizations.homelab.ids[0]
  project_id   = zitadel_project.frigate.id
  role_key     = "admin"
  display_name = "Frigate admin"
}

resource "zitadel_project_role" "frigate_viewer" {
  org_id       = data.zitadel_organizations.homelab.ids[0]
  project_id   = zitadel_project.frigate.id
  role_key     = "viewer"
  display_name = "Frigate viewer"
}

resource "zitadel_application_oidc" "frigate" {
  name       = "Frigate"
  org_id     = data.zitadel_organizations.homelab.ids[0]
  project_id = zitadel_project.frigate.id

  redirect_uris             = ["https://${var.frigate_domain}.${local.magic_fqdn_suffix}/oauth2/callback"]
  post_logout_redirect_uris = ["https://${var.frigate_domain}.${local.magic_fqdn_suffix}/"]

  response_types   = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types      = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"]
  app_type         = "OIDC_APP_TYPE_WEB"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_BASIC"
  dev_mode         = false
}

resource "zitadel_user_grant" "frigate_personal_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.personal.id
  project_id = zitadel_project.frigate.id
  role_keys  = [zitadel_project_role.frigate_admin.role_key]
}

resource "zitadel_user_grant" "frigate_partner_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.partner.id
  project_id = zitadel_project.frigate.id
  role_keys  = [zitadel_project_role.frigate_viewer.role_key]
}

# Zitadel emits granted project roles in the standard
# `urn:zitadel:iam:org:project:roles` claim, but the value is a dict
# (`{"admin": {"<orgId>": "<orgPrimaryDomain>"}}`), not a flat array.
# oauth2-proxy v7.6 cannot extract group names from dict-shaped claims —
# it expects an array of strings.
#
# This Zitadel Action runs in the "Customise Token" flow before userinfo
# generation, walks the user's grants, and emits the role keys for THIS
# project as a flat string array under a new `frigate_groups` claim.
# oauth2-proxy reads from `frigate_groups` (set in the sidecar's
# OAUTH2_PROXY_OIDC_GROUPS_CLAIM) and forwards them as X-Forwarded-Groups
# to nginx → Frigate, where they map directly onto Frigate's `admin` /
# `viewer` role names.
#
# The script filters by projectId so other apps issuing tokens in this
# Zitadel org never receive the frigate_groups claim, avoiding any
# information bleed across services.
#
# Future maintenance: ZITADEL action scripts run on goja (no full ES2015+).
# The body intentionally uses ES5-compatible syntax (var, for-loops).
resource "zitadel_action" "frigate_flatten_groups" {
  org_id          = data.zitadel_organizations.homelab.ids[0]
  name            = "frigateFlattenGroups"
  timeout         = "10s"
  allowed_to_fail = false

  script = <<-JS
    function frigateFlattenGroups(ctx, api) {
      var grants = (ctx.v1.user.grants && ctx.v1.user.grants.grants) || [];
      var groups = [];
      for (var i = 0; i < grants.length; i++) {
        if (grants[i].projectId === '${zitadel_project.frigate.id}' && grants[i].roles) {
          for (var j = 0; j < grants[i].roles.length; j++) {
            groups.push(grants[i].roles[j]);
          }
        }
      }
      if (groups.length > 0) {
        api.v1.claims.setClaim('frigate_groups', groups);
      }
    }
  JS
}

# Bind the action to the pre-userinfo trigger of the Customise Token
# flow. Claims set here land in BOTH the userinfo response and the
# id_token, which is what oauth2-proxy reads.
#
# Caveat: only one zitadel_trigger_actions resource can manage a given
# (flow_type, trigger_type) pair per org. If a future service also needs
# an action on this same trigger, fold its action_id into this list
# (or split the resource into a shared file with action_ids = concat(...)).
resource "zitadel_trigger_actions" "frigate_flatten_groups" {
  org_id       = data.zitadel_organizations.homelab.ids[0]
  flow_type    = "FLOW_TYPE_CUSTOMISE_TOKEN"
  trigger_type = "TRIGGER_TYPE_PRE_USERINFO_CREATION"
  action_ids   = [zitadel_action.frigate_flatten_groups.id]
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
      # Same plaintext as `frigate_password` under homeassist/mosquitto —
      # both keys are written from the single random_password resource in
      # homeassist-mosquitto.tf, so they cannot drift. Mounted here under
      # frigate's own Vault path to avoid granting frigate's vault role
      # read on homeassist/mosquitto.
      mqtt_password = random_password.homeassist_mqtt_frigate.result

      # OIDC client credentials + oauth2-proxy cookie key. oauth2-proxy
      # reads these via env -> secret_key_ref against the synced k8s
      # secret; it never touches /mnt/secrets directly.
      oidc_client_id       = zitadel_application_oidc.frigate.client_id
      oidc_client_secret   = zitadel_application_oidc.frigate.client_secret
      oauth2_cookie_secret = random_password.frigate_oauth2_cookie.result
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
      cameras    = local.frigate_cams
      logout_url = local.frigate_logout_url
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
      server_domain       = "${var.frigate_domain}.${local.magic_fqdn_suffix}"
      nginx_logging_block = local.nginx_logging_blocks["frigate"]
    })
  }
}

# Pod has frigate + nginx + oauth2-proxy + tailscale sidecars in a single
# pod. Cross-ns traffic:
#   - egress  frigate -> oidc:443 (oauth2-proxy → Zitadel)
#   - ingress homeassist -> frigate-internal:5000 (HA Frigate integration)
# Camera ingress is RTSP/ONVIF over the LAN, which doesn't traverse the
# cluster network.
module "frigate_netpol_baseline" {
  source = "../templates/netpol-baseline"

  namespace    = kubernetes_namespace.frigate.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

# Cross-ns egress: oauth2-proxy sidecar -> Zitadel for the OIDC code+PKCE
# flow (discovery, JWKS, token exchange). Pod-scoped per memory
# feedback_netpol_least_privilege. Mirror ingress lives in
# services/zitadel-network.tf as oidc-from-frigate.
resource "kubernetes_network_policy" "frigate_to_oidc" {
  metadata {
    name      = "frigate-to-oidc"
    namespace = kubernetes_namespace.frigate.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = { app = "frigate" }
    }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "oidc"
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

# Cross-ns ingress: homeassist -> nginx:8443 (the in-pod nginx's second
# listener that terminates TLS for the unauth path and proxies to
# Frigate's port 5000). Auth gate is THIS netpol. Mirror egress lives in
# services/homeassist.tf as homeassist-to-frigate-internal.
resource "kubernetes_network_policy" "frigate_internal_from_homeassist" {
  metadata {
    name      = "frigate-internal-from-homeassist"
    namespace = kubernetes_namespace.frigate.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = { app = "frigate" }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.homeassist.metadata[0].name
          }
        }
        pod_selector {
          match_labels = { app = "homeassist" }
        }
      }
      ports {
        protocol = "TCP"
        port     = "8443"
      }
    }
  }
}

# Cluster-internal Service for non-OIDC clients (Home Assistant Frigate
# integration). Routes cluster port 443 → nginx targetPort 8443, where
# the in-pod nginx's second server block terminates TLS with the same
# Let's Encrypt cert used by the OIDC-gated listener and proxies to
# Frigate's unauth port 5000.
#
# Why TLS instead of just exposing port 5000 directly: HA's existing
# integration URL is `https://frigate.<magic>`. host_aliases on the HA
# pod resolves that hostname to this Service's ClusterIP, so HA reaches
# us with Host header = frigate.<magic> (cert validates) on port 443
# (matches the URL).
#
# Reachability is constrained to homeassist-only by
# frigate_internal_from_homeassist. The cert is a regular Let's Encrypt
# cert covering frigate.<magic> only — anyone who can reach this Service
# would still need the magic FQDN to be aliased in /etc/hosts to make
# SNI match.
resource "kubernetes_service" "frigate_internal" {
  metadata {
    name      = "frigate-internal"
    namespace = kubernetes_namespace.frigate.metadata[0].name
  }
  spec {
    selector = { app = "frigate" }
    type     = "ClusterIP"
    port {
      name        = "https"
      port        = 443
      target_port = 8443
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_deployment" "frigate" {
  metadata {
    name      = "frigate"
    namespace = kubernetes_namespace.frigate.metadata[0].name
  }

  # Don't block the apply on rollout readiness. Frigate's first start on a fresh
  # node is slow (≈5GB :stable-rocm pull + first-run ONNX→.mxr conversion + ffmpeg
  # warmup), which exceeds Terraform's default rollout wait and makes apply
  # "time out" even though the Deployment applied fine. With this, apply records
  # the object and returns; watch readiness with kubectl instead.
  wait_for_rollout = false

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
          "secret.reloader.stakater.com/reload" = "${module.frigate_tls_vault.tls_secret_name},${module.frigate_tls_vault.config_secret_name}"
          # Recordings are large + ephemeral by design; events DB is rebuilt on
          # restore as cameras start producing new footage. Excluded from FSB.
          "backup.velero.io/backup-volumes-excludes" = "frigate-recordings,frigate-config"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.frigate.metadata[0].name

        # Needed for the seed-model init's frigate-model:latest pull from the
        # in-cluster registry (other images are public). Applies pod-wide but is
        # a no-op for anonymous/public pulls.
        image_pull_secrets {
          name = kubernetes_secret.frigate_registry_pull_secret.metadata[0].name
        }

        # Pin oidc.<tailnet> to the Zitadel ClusterIP for SNI/cert validation
        # without a Tailscale egress sidecar (memory: feedback_no_egress_only_ts_sidecars).
        # oauth2-proxy speaks to Zitadel via this alias for discovery, JWKS,
        # token exchange, and userinfo.
        host_aliases {
          ip        = data.terraform_remote_state.vault_conf.outputs.zitadel_cluster_ip
          hostnames = ["${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"]
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

        # Pinned to the artemis GPU node — the R9700s + ROCm live there; Coral
        # is retired and detection moves to gfx1201 via the onnx detector.
        # node_selector pulls it onto artemis; the toleration clears the
        # gpu=true:NoSchedule taint. (supplemental_groups above are the
        # video/render GIDs — verify they match artemis: `getent group render
        # video`; privileged+root makes them belt-and-suspenders, but a
        # non-root detector reaching /dev/kfd needs the right render GID.)
        node_selector = { node = "artemis" }
        toleration {
          key      = "gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "oidc_client_id"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Seed the self-built YOLOv9-c ONNX into /config/model_cache/yolo.onnx.
        # Frigate's onnx detector ships no model and does NOT auto-download on
        # the ROCm path, so the frigate-model image (services/frigate-jobs.tf)
        # carries /model.onnx and we copy it in on every start. cp -f is
        # idempotent; a rebuilt model rolls the pod via the image ref change.
        init_container {
          name              = "seed-model"
          image             = local.frigate_model_image
          image_pull_policy = "Always"
          command           = ["sh", "-c", "mkdir -p /config/model_cache && cp -f /model.onnx /config/model_cache/yolo.onnx"]
          volume_mount {
            name       = "frigate-config"
            mount_path = "/config"
          }
        }

        # Frigate
        container {
          name  = "frigate"
          image = var.image_frigate
          image_pull_policy = "Always"

          # Without privileged the container's cgroup device whitelist
          # blocks open() on /dev/dri/renderD129 (VAAPI) and /dev/kfd
          # (ROCm) even though the files are visible (DAC perms are
          # necessary but not sufficient — k8s separately gates *use* of
          # host devices). Symptom: ffmpeg "No VA display found" or the
          # onnx detector's MIGraphX EP failing to init (HIP "no ROCm-capable
          # device"). Proper fix is the amd.com/gpu device plugin; privileged
          # is the one-liner workaround until that lands.
          security_context {
            privileged = true
          }

          port {
            container_port = 8971
            name           = "https-auth"
          }

          # Frigate's port 5000 is the unauth integration channel. Only
          # nginx (same pod, localhost) reaches it — exposing the port at
          # the pod level isn't required for that, but declaring it here
          # documents the listener for anyone reading the manifest.
          port {
            container_port = 5000
            name           = "http-unauth"
          }

          env {
            name  = "TZ"
            value = var.homeassist_time_zone
          }

          # Force AMD's mesa VA-API driver. The :stable image bundles
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
          # AMD compute device for the ROCm onnx detector — /dev/kfd is the
          # kernel fusion driver ROCm enqueues inference kernels through.
          # Paired with /dev/dri above (VAAPI decode + ROCm both need dri).
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

          # Memory limit is sized for the MIGraphX first-run compile, not
          # steady state. On first detector init the ROCm/MIGraphX EP compiles
          # the YOLOv9-c@640 ONNX to a `.mxr` for gfx1201, and that compile
          # transiently spikes host RAM far past frigate's ~1-2Gi steady-state
          # footprint — 4Gi OOM-killed the pod mid-compile. 16Gi rides out the
          # spike; the `.mxr` caches to model_cache/ so later starts skip it.
          # Request stays modest so the scheduler doesn't reserve the spike.
          resources {
            requests = { cpu = "500m", memory = "2Gi" }
            limits   = { cpu = "4000m", memory = "16Gi" }
          }

          # Detector cold start on ROCm includes the MIGraphX compile above;
          # keep a buffer for Frigate web app boot + ffmpeg per-cam warm-up.
          liveness_probe {
            tcp_socket {
              port = 8971
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            timeout_seconds       = 10
            failure_threshold     = 5
          }

          readiness_probe {
            tcp_socket {
              port = 8971
            }
            initial_delay_seconds = 30
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

        # oauth2-proxy: handles the OIDC code+PKCE flow against Zitadel
        # and tells nginx (via the auth_request subrequest at /oauth2/auth)
        # who the signed-in user is + which Zitadel project roles they
        # hold. nginx forwards those as X-Forwarded-User /
        # X-Forwarded-Groups to Frigate's port 8971 (auth.enabled: false +
        # proxy.header_map). Listens on 127.0.0.1:4180 — only nginx in
        # this same pod ever talks to it.
        container {
          name  = "frigate-oauth2-proxy"
          image = var.image_oauth2_proxy
          image_pull_policy = "Always"

          env {
            name  = "OAUTH2_PROXY_PROVIDER"
            value = "oidc"
          }
          env {
            name  = "OAUTH2_PROXY_OIDC_ISSUER_URL"
            value = "https://${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"
          }
          env {
            name  = "OAUTH2_PROXY_REDIRECT_URL"
            value = "https://${var.frigate_domain}.${local.magic_fqdn_suffix}/oauth2/callback"
          }
          env {
            name  = "OAUTH2_PROXY_HTTP_ADDRESS"
            value = "127.0.0.1:4180"
          }
          env {
            name  = "OAUTH2_PROXY_REVERSE_PROXY"
            value = "true"
          }
          # Auth-only mode. nginx talks to Frigate's port 8971 directly;
          # oauth2-proxy just answers the /oauth2/auth subrequest.
          env {
            name  = "OAUTH2_PROXY_UPSTREAMS"
            value = "static://202"
          }
          # Project access is enforced by Zitadel's project_role_check.
          # Email-domain filtering would be additional defence in depth
          # but we don't currently scope identities to a single domain.
          env {
            name  = "OAUTH2_PROXY_EMAIL_DOMAINS"
            value = "*"
          }
          # The Zitadel project-roles claim is non-standard; explicit
          # scope request makes Zitadel emit it AND triggers the
          # frigate_flatten_groups action below to copy the role keys
          # into a flat `frigate_groups` array claim.
          env {
            name  = "OAUTH2_PROXY_SCOPE"
            value = "openid email profile urn:zitadel:iam:org:project:roles"
          }
          # Read groups from `frigate_groups` (a flat string array set by
          # the Zitadel pre-userinfo action). oauth2-proxy v7.6 cannot
          # extract group names from Zitadel's native dict-shaped
          # `urn:zitadel:iam:org:project:roles` claim — only arrays/strings.
          # The action sidesteps that.
          env {
            name  = "OAUTH2_PROXY_OIDC_GROUPS_CLAIM"
            value = "frigate_groups"
          }
          env {
            name  = "OAUTH2_PROXY_SET_XAUTHREQUEST"
            value = "true"
          }
          env {
            name  = "OAUTH2_PROXY_PASS_USER_HEADERS"
            value = "true"
          }
          # Single-IdP setup; skip the provider-picker page that oauth2-proxy
          # otherwise shows before redirecting to Zitadel.
          env {
            name  = "OAUTH2_PROXY_SKIP_PROVIDER_BUTTON"
            value = "true"
          }
          env {
            name  = "OAUTH2_PROXY_COOKIE_SECURE"
            value = "true"
          }
          env {
            name  = "OAUTH2_PROXY_COOKIE_DOMAINS"
            value = "${var.frigate_domain}.${local.magic_fqdn_suffix}"
          }
          # Whitelist both frigate.<magic> and oidc.<magic>: oauth2-proxy
          # validates `?rd=` redirects against this list, and the
          # RP-initiated logout chain (local.frigate_logout_url) bounces
          # the browser to oidc.<magic>/oidc/v1/end_session.
          env {
            name  = "OAUTH2_PROXY_WHITELIST_DOMAINS"
            value = "${var.frigate_domain}.${local.magic_fqdn_suffix},${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"
          }

          env {
            name = "OAUTH2_PROXY_CLIENT_ID"
            value_from {
              secret_key_ref {
                name = module.frigate_tls_vault.config_secret_name
                key  = "oidc_client_id"
              }
            }
          }
          env {
            name = "OAUTH2_PROXY_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = module.frigate_tls_vault.config_secret_name
                key  = "oidc_client_secret"
              }
            }
          }
          env {
            name = "OAUTH2_PROXY_COOKIE_SECRET"
            value_from {
              secret_key_ref {
                name = module.frigate_tls_vault.config_secret_name
                key  = "oauth2_cookie_secret"
              }
            }
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        # Nginx
        container {
          name  = "frigate-nginx"
          image = var.image_nginx
          image_pull_policy = "Always"

          port {
            container_port = 443
            name           = "https"
          }

          # Second TLS listener used only by the cluster-internal
          # frigate-internal Service (port 443 → 8443). No oauth2-proxy
          # gate; reverse-proxies to Frigate's unauth port 5000 for the
          # Home Assistant integration. Reuses the same cert.
          port {
            container_port = 8443
            name           = "https-int"
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
          image_pull_policy = "Always"

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

          # Tailscale sidecar does WireGuard crypto in userspace (wireguard-go)
          # even with TS_USERSPACE=false, charged to this cgroup. Headroom so
          # the in-pod sidecar isn't the throughput cap for video (Frigate VOD).
          # NOTE: the ~9.5 Mbps playback bug was NOT this limit — it was a host
          # NIC issue (atlantic-driver UDP-GSO mangling WireGuard UDP), fixed in
          # cluster/modules/node-provision-server, not here.
          resources {
            requests = {
              cpu    = "100m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "2000m"
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
    # seed-model init pulls frigate-model:latest — wait for the build job to
    # push it (the module blocks until the Job completes) before rolling.
    module.frigate_model_build,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}
