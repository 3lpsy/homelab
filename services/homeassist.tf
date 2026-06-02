# Home Assistant pod (HA + nginx TLS terminator + tailscale sidecar).
#
# The `homeassist` namespace also hosts homeassist-mosquitto.tf and
# homeassist-z2m.tf. They share:
#   - this namespace
#   - vault_policy.homeassist (declared here, granting `homeassist/*` read)
#   - per-service vault_kubernetes_auth_backend_role.* (each declared in
#     its own file, all referencing this policy)
# Each service's tls_vault module call uses manage_vault_auth=false so the
# modules don't create competing policies, and pass role_name=<service>
# so SPCs reference the externally-managed auth role.

resource "kubernetes_namespace" "homeassist" {
  metadata {
    name = "homeassist"
  }
}

resource "kubernetes_service_account" "homeassist" {
  metadata {
    name      = "homeassist"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  automount_service_account_token = false
}

# Pull-secret for the in-cluster registry — needed because the homeassist
# Deployment now uses a custom-built image (data/images/homeassist/) pushed
# to registry.<tailnet> by services/homeassist-jobs.tf. Same shape as
# services/nextcloud-secrets.tf: copies the shared `internal` registry
# user's password into a per-namespace dockerconfigjson Secret.
resource "kubernetes_secret" "homeassist_registry_pull_secret" {
  metadata {
    name      = "registry-pull-secret"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${var.registry_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}" = {
          username = "internal"
          password = random_password.registry_user_passwords["internal"].result
          auth     = base64encode("internal:${random_password.registry_user_passwords["internal"].result}")
        }
      }
    })
  }
}

resource "random_password" "homeassist_admin" {
  length  = 32
  special = false
}

# Shared policy: every service in this namespace gets read access to its
# own subtree under `homeassist/*`. mosquitto + z2m reference this same
# policy from their own vault_kubernetes_auth_backend_role.* below.
resource "vault_policy" "homeassist" {
  name = "homeassist-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/homeassist/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "homeassist" {
  backend                          = "kubernetes"
  role_name                        = "homeassist"
  bound_service_account_names      = [kubernetes_service_account.homeassist.metadata[0].name]
  bound_service_account_namespaces = [kubernetes_namespace.homeassist.metadata[0].name]
  token_policies                   = [vault_policy.homeassist.name]
  token_ttl                        = 86400
}

module "homeassist_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "homeassist"
  namespace            = kubernetes_namespace.homeassist.metadata[0].name
  service_account_name = kubernetes_service_account.homeassist.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.homeassist_server_user
}

module "homeassist_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "homeassist"
  namespace            = kubernetes_namespace.homeassist.metadata[0].name
  service_account_name = kubernetes_service_account.homeassist.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = "${var.homeassist_domain}.${local.magic_fqdn_suffix}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  config_secrets = {
    admin_password     = random_password.homeassist_admin.result
    oidc_client_id     = zitadel_application_oidc.homeassist.client_id
    oidc_client_secret = zitadel_application_oidc.homeassist.client_secret
  }

  # ha_password lives in homeassist/mosquitto (owned by mosquitto's
  # vault_kv_secret_v2). Surface it in homeassist-secrets so the seed-mqtt
  # init container can read it under /mnt/secrets/ha_password.
  extra_config_keys = [
    {
      object_name = "ha_password"
      vault_path  = "homeassist/mosquitto"
      vault_key   = "ha_password"
    }
  ]

  manage_vault_auth = false
  role_name         = vault_kubernetes_auth_backend_role.homeassist.role_name

  providers = { acme = acme }

  depends_on = [vault_kv_secret_v2.homeassist_mosquitto]
}

# ─── Zitadel project + OIDC application + per-user grant ─────────────────────
#
# Per memory `feedback_zitadel_one_project_per_service`, each service onboarded
# to Zitadel SSO declares its own project. The redirect URI matches what the
# hass-oidc-auth integration registers internally.
resource "zitadel_project" "homeassist" {
  name   = "homeassist"
  org_id = data.zitadel_organizations.homelab.ids[0]

  project_role_assertion   = false
  project_role_check       = false
  has_project_check        = false
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"
}

resource "zitadel_application_oidc" "homeassist" {
  name       = "Home Assistant"
  org_id     = data.zitadel_organizations.homelab.ids[0]
  project_id = zitadel_project.homeassist.id

  redirect_uris             = ["https://${var.homeassist_domain}.${local.magic_fqdn_suffix}/auth/oidc/callback"]
  post_logout_redirect_uris = ["https://${var.homeassist_domain}.${local.magic_fqdn_suffix}/"]

  response_types   = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types      = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"]
  app_type         = "OIDC_APP_TYPE_WEB"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_BASIC"
  dev_mode         = false
}

# Explicit grant for `jim`. No-op for authz enforcement today (HA's own
# permission model is flat — every authenticated user sees everything).
# Pre-positioned for if/when project_role_check is flipped on later.
resource "zitadel_user_grant" "homeassist_personal_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.personal.id
  project_id = zitadel_project.homeassist.id
  role_keys  = []
}

resource "zitadel_user_grant" "homeassist_partner_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.partner.id
  project_id = zitadel_project.homeassist.id
  role_keys  = []
}

# NetworkPolicies for the `homeassist` namespace.
#
# Hosts: home-assistant, mosquitto MQTT broker, zigbee2mqtt. Most
# cross-pod traffic is intra-namespace (HA → mosquitto:1883, z2m →
# mosquitto:1883). Z2M and HA both also expose UIs that are reached
# externally via Tailscale sidecars (NetPol-invisible).
#
# Cross-ns ingress for Frigate → mosquitto:1883 lives in
# `services/frigate-network.tf` (kept with the rest of frigate's wiring).
module "homeassist_netpol_baseline" {
  source = "../templates/netpol-baseline"

  namespace    = kubernetes_namespace.homeassist.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

# Cross-ns egress: homeassist → oidc:443 for OIDC code+PKCE flow.
# Mirror ingress lives in services/zitadel-network.tf as oidc-from-homeassist.
resource "kubernetes_network_policy" "homeassist_to_oidc" {
  metadata {
    name      = "homeassist-to-oidc"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = { app = "homeassist" }
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

# Cross-ns egress: homeassist → nginx:8443 in the frigate pod (the
# in-pod second nginx listener that fronts Frigate's unauth port 5000
# with TLS, no OIDC gate). HA's URL stays `https://frigate.<magic>`;
# host_aliases on the homeassist pod resolves that hostname to the
# frigate-internal Service ClusterIP, which routes 443 → 8443. This
# netpol is the only thing scoping the unauth path to homeassist. Mirror
# ingress lives in services/frigate.tf as frigate_internal_from_homeassist.
resource "kubernetes_network_policy" "homeassist_to_frigate_internal" {
  metadata {
    name      = "homeassist-to-frigate-internal"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = { app = "homeassist" }
    }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.frigate.metadata[0].name
          }
        }
        pod_selector {
          match_labels = { app = "frigate" }
        }
      }
      ports {
        protocol = "TCP"
        port     = "8443"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "homeassist_config" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "homeassist-config"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = "20Gi"
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_config_map" "homeassist_config" {
  metadata {
    name      = "homeassist-config"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  data = {
    # Seed configuration.yaml. The seed-config init container copies this
    # to /config/configuration.yaml on first boot only — subsequent edits
    # via the HA UI / file editor live on the PVC and are not overwritten.
    "configuration.yaml" = <<-EOT
      default_config:

      # Pulls in TF-authoritative YAML packages from /config/packages/
      # (one file per concern). Currently used for Frigate notification
      # automations rendered by services/homeassist.tf into the
      # `homeassist-packages` ConfigMap.
      homeassistant:
        packages: !include_dir_named packages

      http:
        use_x_forwarded_for: true
        trusted_proxies:
          - 127.0.0.1
          - ::1

      logger:
        default: info

      # SSO via Zitadel through hass-oidc-auth (custom component baked
      # into the homeassist image — see data/images/homeassist/Dockerfile).
      # The auth_oidc block itself is in /config/auth_oidc.yaml, rendered
      # on every pod start by the seed-auth-oidc init container from CSI
      # secrets (Vault-backed). Idempotent — see
      # data/homeassist/render-auth-oidc.py for details.
      auth_oidc: !include auth_oidc.yaml

      automation: !include automations.yaml
      script: !include scripts.yaml
      scene: !include scenes.yaml
    EOT
  }
}

resource "kubernetes_config_map" "homeassist_packages" {
  metadata {
    name      = "homeassist-packages"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  data = {
    "frigate_notifications.yaml" = templatefile("${path.module}/../data/homeassist/packages/frigate_notifications.yaml.tpl", {
      # Only cams with notifications=true opt into the HA push automation.
      cameras        = { for name, cam in local.frigate_cams : name => cam if cam.notifications }
      notify_devices = var.homeassist_notify_devices
      frigate_url    = "${var.frigate_domain}.${local.magic_fqdn_suffix}"
    })
  }
}

resource "kubernetes_config_map" "homeassist_init_scripts" {
  metadata {
    name      = "homeassist-init-scripts"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  data = {
    # Plain scripts; secrets are read at runtime from /mnt/secrets via the
    # CSI mount, so no secret ever lands in this ConfigMap.
    "seed-mqtt-broker.py" = file("${path.module}/../data/homeassist/seed-mqtt-broker.py")
    "render-auth-oidc.py" = file("${path.module}/../data/homeassist/render-auth-oidc.py")
  }
}

resource "kubernetes_config_map" "homeassist_nginx_config" {
  metadata {
    name      = "homeassist-nginx-config"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/homeassist.nginx.conf.tpl", {
      server_domain       = "${var.homeassist_domain}.${local.magic_fqdn_suffix}"
      nginx_logging_block = local.nginx_logging_blocks["homeassist"]
    })
  }
}

resource "kubernetes_deployment" "homeassist" {
  metadata {
    name      = "homeassist"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "homeassist" }
    }

    template {
      metadata {
        labels = { app = "homeassist" }
        annotations = {
          "config-hash"                         = sha1(kubernetes_config_map.homeassist_config.data["configuration.yaml"])
          "init-scripts-hash"                   = sha1("${kubernetes_config_map.homeassist_init_scripts.data["seed-mqtt-broker.py"]}|${kubernetes_config_map.homeassist_init_scripts.data["render-auth-oidc.py"]}")
          "packages-hash"                       = sha1(jsonencode(kubernetes_config_map.homeassist_packages.data))
          "nginx-config-hash"                   = sha1(kubernetes_config_map.homeassist_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "${module.homeassist_tls_vault.tls_secret_name},${module.homeassist_tls_vault.config_secret_name}"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.homeassist.metadata[0].name
        image_pull_secrets {
          name = kubernetes_secret.homeassist_registry_pull_secret.metadata[0].name
        }

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
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

        # Copies the seeded configuration.yaml onto the PVC the first time the
        # pod starts, then ensures the !include target files exist so HA's
        # config validator doesn't fail before the user has created any
        # automations/scripts/scenes. Idempotent: subsequent boots skip the
        # copy if /config/configuration.yaml already exists, so user edits
        # made via the HA UI are preserved.
        init_container {
          name  = "seed-config"
          image = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            <<-EOT
              if [ ! -f /config/configuration.yaml ]; then
                cp /etc/configuration-seed/configuration.yaml /config/configuration.yaml
              fi
              touch /config/automations.yaml /config/scripts.yaml /config/scenes.yaml
              # Idempotent: existing PVCs predate the packages include and
              # would otherwise need a manual edit. Two paths so we don't
              # create a duplicate `homeassistant:` block when the user has
              # one already (timezone/location etc. set via HA wizard):
              #   - block exists  -> insert `  packages: …` line under it
              #   - block missing -> prepend a fresh block at top of file
              # Subsequent runs are no-ops thanks to the outer grep guard.
              if ! grep -q 'packages: !include_dir_named' /config/configuration.yaml; then
                if grep -q '^homeassistant:[[:space:]]*$' /config/configuration.yaml; then
                  sed -i '/^homeassistant:[[:space:]]*$/a\  packages: !include_dir_named packages' /config/configuration.yaml
                  echo "Injected packages: under existing homeassistant: block"
                else
                  sed -i '1i homeassistant:\n  packages: !include_dir_named packages\n' /config/configuration.yaml
                  echo "Prepended homeassistant: block with packages include"
                fi
              fi
            EOT
          ]
          volume_mount {
            name       = "homeassist-data"
            mount_path = "/config"
          }
          volume_mount {
            name       = "homeassist-config-seed"
            mount_path = "/etc/configuration-seed"
            read_only  = true
          }
        }

        # Sync TF-rendered HA packages onto the PVC under /config/packages/.
        # Authoritative: every boot wipes and re-copies, so changes to
        # data/homeassist/packages/*.yaml.tpl propagate on the next pod
        # restart (Reloader bounces the pod when the ConfigMap changes via
        # the packages-hash annotation). Manual edits to /config/packages/
        # files are intentionally not preserved — edit the .tpl source.
        init_container {
          name  = "seed-packages"
          image = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            <<-EOT
              set -e
              mkdir -p /config/packages
              # Wipe TF-managed files only (ones we ship in the ConfigMap),
              # leaving any user-dropped packages alone.
              for f in /etc/homeassist-packages/*.yaml; do
                base=$(basename "$f")
                cp "$f" "/config/packages/$base"
              done
              echo "synced $(ls /etc/homeassist-packages/ | wc -l) package(s)"
            EOT
          ]
          volume_mount {
            name       = "homeassist-data"
            mount_path = "/config"
          }
          volume_mount {
            name       = "homeassist-packages"
            mount_path = "/etc/homeassist-packages"
            read_only  = true
          }
        }

        # Install the hass-oidc-auth custom component into the PVC's
        # custom_components/ dir. The integration files are baked into
        # /extras/ inside the custom HA image (data/images/homeassist/
        # Dockerfile) — we can't bake them under /config/... directly
        # because the PVC mount hides anything at that path.
        # Always overwrites: a Dockerfile bump (new HASS_OIDC_AUTH_VERSION)
        # then propagates on next pod restart without manual cleanup.
        init_container {
          name  = "install-auth-oidc"
          image = local.homeassist_image
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            <<-EOT
              set -e
              mkdir -p /config/custom_components
              rm -rf /config/custom_components/auth_oidc
              cp -a /extras/custom_components/auth_oidc /config/custom_components/auth_oidc
              echo "auth_oidc custom component installed"
            EOT
          ]
          volume_mount {
            name       = "homeassist-data"
            mount_path = "/config"
          }
        }

        # Skips the HA web onboarding wizard end-to-end:
        #  1. Pre-creates the admin via `hass --script auth add`. Idempotent:
        #     if the user already exists (manual onboarding or earlier apply),
        #     the init leaves the password alone so a UI-changed password is
        #     never silently reverted to the Vault value. Read the initial
        #     password with `vault kv get -field=admin_password secret/homeassist/config`.
        #  2. Pre-writes /config/.storage/onboarding marking all four wizard
        #     steps (user, core_config, analytics, integration) done so HA
        #     routes to the login page instead of /onboarding.html. Storage
        #     format matches homeassistant.components.onboarding STORAGE_VERSION
        #     = 4. Idempotent: only writes if the file is missing, so a
        #     partially-completed manual wizard isn't clobbered.
        init_container {
          name  = "seed-admin-user"
          image = local.homeassist_image
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            <<-EOT
              set -e
              USERNAME="${var.homeassist_admin_user}"
              PASSWORD=$(cat /mnt/secrets/admin_password)
              if [ -z "$PASSWORD" ]; then
                echo "ERROR: admin_password secret is empty" >&2
                exit 1
              fi
              EXISTING=$(hass --script auth -c /config list 2>/dev/null || true)
              if echo "$EXISTING" | grep -qE "^$USERNAME$"; then
                echo "User $USERNAME already exists, leaving password alone"
              else
                echo "Creating user $USERNAME..."
                hass --script auth -c /config add "$USERNAME" "$PASSWORD"
              fi
              # Always overwrite: HA may have written a partial-done file
              # mid-cancelled-wizard on a prior pod run. The data shape here
              # is "all four steps done" regardless of prior state, and the
              # actual user-configurable settings (timezone, location, etc.)
              # live in *other* .storage files that we don't touch.
              mkdir -p /config/.storage
              printf '%s' '{"version":4,"minor_version":1,"key":"onboarding","data":{"done":["user","core_config","analytics","integration"]}}' > /config/.storage/onboarding
              echo "Marked onboarding wizard complete"

              # Seed core.config with Austin/Central/US defaults so HA isn't
              # left at UTC + EUR + no country (which trips the "country not
              # configured" repair issue and breaks integrations that key off
              # locale). Storage layout matches homeassistant.core_config
              # CORE_STORAGE_VERSION=1 / MINOR_VERSION=4. Idempotent: only
              # writes when the file is missing or country is still null
              # (HA's unset sentinel), so a UI-set country/location/lat-long
              # is never reverted on later pod restarts.
              if [ ! -f /config/.storage/core.config ] || grep -q '"country": *null' /config/.storage/core.config 2>/dev/null; then
                printf '%s' '{"version":1,"minor_version":4,"key":"core.config","data":{"latitude":30.2672,"longitude":-97.7431,"elevation":149,"radius":100,"unit_system_v2":"us_customary","location_name":"Home","time_zone":"${var.homeassist_time_zone}","external_url":null,"internal_url":"https://${var.homeassist_domain}.${local.magic_fqdn_suffix}","currency":"USD","country":"US","language":"en"}}' > /config/.storage/core.config
                echo "Seeded core.config with US/Austin/Central defaults"
              else
                echo "core.config already configured, leaving alone"
              fi
            EOT
          ]
          volume_mount {
            name       = "homeassist-data"
            mount_path = "/config"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Render auth_oidc config every pod start. Writes
        # /config/auth_oidc.yaml from /mnt/secrets and ensures
        # configuration.yaml has the `auth_oidc: !include auth_oidc.yaml`
        # line (and strips any stale inline block from earlier attempts).
        # Idempotent — see data/homeassist/render-auth-oidc.py.
        init_container {
          name    = "seed-auth-oidc"
          image   = var.image_python
          image_pull_policy = "Always"
          command = ["python3", "/scripts/render-auth-oidc.py"]
          env {
            name  = "OIDC_DISCOVERY_URL"
            value = "https://${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}/.well-known/openid-configuration"
          }
          volume_mount {
            name       = "homeassist-data"
            mount_path = "/config"
          }
          volume_mount {
            name       = "homeassist-init-scripts"
            mount_path = "/scripts"
            read_only  = true
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Pre-wires the MQTT integration so HA talks to the in-cluster
        # mosquitto broker without a manual UI config-flow, and so Vault
        # rotations of homeassist/mosquitto:ha_password flow through to HA
        # automatically (Reloader bounces this pod, init re-runs, password is
        # patched in place). Logic lives in data/homeassist/seed-mqtt-broker.py
        # — see the docstring there for first-boot vs. patch behavior. The
        # ConfigMap holds only the script; the password is read at runtime
        # from /mnt/secrets so no secret leaks into the ConfigMap.
        init_container {
          name    = "seed-mqtt-broker"
          image   = var.image_python
          image_pull_policy = "Always"
          command = ["python3", "/scripts/seed-mqtt-broker.py"]
          volume_mount {
            name       = "homeassist-data"
            mount_path = "/config"
          }
          volume_mount {
            name       = "homeassist-init-scripts"
            mount_path = "/scripts"
            read_only  = true
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Pin oidc.<tailnet> to the in-cluster Zitadel ClusterIP. HA fetches
        # /.well-known/openid-configuration at integration load time and
        # again on each token exchange — going through Tailscale egress is
        # unnecessary and slower. SNI carries the FQDN so the LE cert
        # validates against the ClusterIP.
        host_aliases {
          ip        = data.terraform_remote_state.vault_conf.outputs.zitadel_cluster_ip
          hostnames = ["${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"]
        }

        # Pin frigate.<tailnet> to the in-cluster `frigate-internal` Service
        # ClusterIP. The matching Service routes 443 → nginx 8443, where a
        # second nginx listener (no OIDC gate) terminates TLS with Frigate's
        # existing LE cert and proxies to Frigate's unauth port 5000. HA
        # keeps using its existing `https://frigate.<magic>` URL — host_aliases
        # short-circuits the tailnet round-trip and the OIDC gate that the
        # tailnet path now enforces. SNI = frigate.<magic> so the cert
        # validates against this ClusterIP.
        host_aliases {
          ip        = kubernetes_service.frigate_internal.spec[0].cluster_ip
          hostnames = ["${var.frigate_domain}.${local.magic_fqdn_suffix}"]
        }

        # Home Assistant
        container {
          name  = "homeassistant"
          image = local.homeassist_image
          image_pull_policy = "Always"

          port {
            container_port = 8123
            name           = "http"
          }

          env {
            name  = "TZ"
            value = var.homeassist_time_zone
          }
          # OIDC client creds are NOT injected here as env vars — they
          # land in /config/auth_oidc.yaml via the seed-auth-oidc init
          # container, which reads them from /mnt/secrets and writes
          # literal YAML. HA reads /config/auth_oidc.yaml via !include.

          volume_mount {
            name       = "homeassist-data"
            mount_path = "/config"
          }
          # Pins the CSI secrets-store volume so the synced `homeassist-tls`
          # k8s secret stays alive for the nginx sidecar; HA itself never
          # reads from this path.
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "500m", memory = "512Mi" }
            limits   = { cpu = "2000m", memory = "2Gi" }
          }

          liveness_probe {
            tcp_socket {
              port = 8123
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            timeout_seconds       = 10
            failure_threshold     = 5
          }

          readiness_probe {
            tcp_socket {
              port = 8123
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        # Home Assistant Volumes
        volume {
          name = "homeassist-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.homeassist_config.metadata[0].name
          }
        }
        volume {
          name = "homeassist-config-seed"
          config_map {
            name = kubernetes_config_map.homeassist_config.metadata[0].name
          }
        }
        volume {
          name = "homeassist-init-scripts"
          config_map {
            name         = kubernetes_config_map.homeassist_init_scripts.metadata[0].name
            default_mode = "0555"
          }
        }

        volume {
          name = "homeassist-packages"
          config_map {
            name = kubernetes_config_map.homeassist_packages.metadata[0].name
          }
        }

        # Nginx
        container {
          name  = "homeassist-nginx"
          image = var.image_nginx
          image_pull_policy = "Always"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "homeassist-tls"
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
          name = "homeassist-tls"
          secret { secret_name = module.homeassist_tls_vault.tls_secret_name }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.homeassist_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.homeassist_tls_vault.spc_name
            }
          }
        }

        # Tailscale
        container {
          name  = "homeassist-tailscale"
          image = var.image_tailscale
          image_pull_policy = "Always"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.homeassist_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.homeassist_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.homeassist_domain
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
    module.homeassist_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}
