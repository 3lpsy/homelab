# Forgejo — homelab git forge replacing the opencode-bundled
# git-http-backend sidecar. SQLite + bare repos on one PVC; HTTPS via the
# tailscale ingress sidecar (advertises tcp/443 → nginx + tcp/22 →
# forgejo's in-pod SSH on :2222 since the rootless container can't bind
# <1024). Zitadel OIDC via in-cluster host_aliases pin.
#
# Opencode reaches Forgejo over the in-cluster Service (host_aliases pins
# `${var.git_domain}.<magic>` → ClusterIP, no tailnet ACL needed; see
# `feedback_no_egress_only_ts_sidecars`). Personal devices reach git via
# tailnet on :443/:22 per acls_git in homelab/modules/tailnet-infra/acls.tf.
#
# Post-deploy config (admin user, OIDC auth source, personal+opencode
# users, SSH key registration) lives in data/scripts/forgejo-bootstrap.sh.tpl
# and runs as a kubernetes_job_v1; idempotent — re-runs on every script /
# secret hash change.

locals {
  git_fqdn = "${var.git_domain}.${local.magic_fqdn_suffix}"

  git_app_ini = templatefile("${path.module}/../data/forgejo/app.ini.tpl", {
    git_fqdn     = local.git_fqdn
    magic_domain = "${var.headscale_subdomain}.${var.headscale_magic_domain}"
  })

  git_zitadel_fqdn = "${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"

  git_bootstrap_script = templatefile("${path.module}/../data/scripts/forgejo-bootstrap.sh.tpl", {
    git_fqdn          = local.git_fqdn
    zitadel_fqdn      = local.git_zitadel_fqdn
    magic_domain      = "${var.headscale_subdomain}.${var.headscale_magic_domain}"
    personal_username = var.zitadel_personal_user.user_name
    # Per user_identity_convention: seed local users with the username form
    # (<user_name>@<magic_domain>), NOT var.zitadel_personal_user.email
    # (contact email). Trade-off: Forgejo's OIDC ACCOUNT_LINKING=auto
    # matches by email claim which Zitadel sets from its user record's
    # email field (typically the contact email) — so silent auto-link
    # won't fire. First sign-in shows the /user/link_account prompt;
    # enter the personal_user_password from Vault once and the OIDC
    # binding is permanent (subsequent sign-ins go straight through).
    personal_email = "${var.zitadel_personal_user.user_name}@${var.headscale_magic_domain}"
    # Title carries a content-hash suffix so rotating either pub key
    # invalidates the existence check and forces a fresh POST. Old keys
    # under prior titles linger in Forgejo (no auto-cleanup) — manual
    # remove via UI: Settings → SSH/GPG Keys.
    personal_key_title = "personal-default-${substr(sha256(var.git_personal_user_ssh_pub_key), 0, 12)}"
    opencode_key_title = "opencode-cluster-${substr(sha256(tls_private_key.opencode_git_ssh.public_key_openssh), 0, 12)}"
  })
}

resource "kubernetes_namespace" "git" {
  metadata {
    name = "git"
  }
}

resource "kubernetes_service_account" "git" {
  metadata {
    name      = "git"
    namespace = kubernetes_namespace.git.metadata[0].name
  }
  automount_service_account_token = false
}

# ─── Secrets (Vault is canonical) ─────────────────────────────────────────────
resource "random_password" "git_secret_key" {
  length  = 64
  special = false
}

resource "random_password" "git_internal_token" {
  length  = 64
  special = false
}

resource "random_password" "git_oauth2_jwt" {
  length  = 43
  special = false
}

resource "random_password" "git_lfs_jwt" {
  length  = 43
  special = false
}

resource "random_password" "git_admin_password" {
  length  = 32
  special = false
}

resource "random_password" "git_opencode_password" {
  length  = 32
  special = false
}

# Local password for the pre-created personal Forgejo user. Only needed
# as a one-time fallback for the `/user/link_account` prompt that appears
# when Forgejo's auto-link doesn't fire (e.g. email-verified mismatch).
# After the OIDC link is established, this password is dead weight —
# OIDC sign-in is the only practical path.
resource "random_password" "git_personal_password" {
  length  = 32
  special = false
}

# ─── Zitadel project + OIDC application ──────────────────────────────────────
# Own project per `feedback_zitadel_one_project_per_service`.
# has_project_check=true: Zitadel refuses to mint an id_token for this
# client unless the user has a project grant. Combined with
# ENABLE_AUTO_REGISTRATION=false in app.ini and the single grant below
# (personal user only), this is the cluster-wide gate keeping unknown
# Zitadel identities out of Forgejo — even compromised Zitadel accounts
# without the explicit grant get blocked at token issuance.
resource "zitadel_project" "git" {
  name   = "git"
  org_id = data.zitadel_organizations.homelab.ids[0]

  project_role_assertion   = false
  project_role_check       = false
  has_project_check        = true
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"
}

resource "zitadel_application_oidc" "git" {
  name       = "Forgejo"
  org_id     = data.zitadel_organizations.homelab.ids[0]
  project_id = zitadel_project.git.id

  redirect_uris             = ["https://${local.git_fqdn}/user/oauth2/zitadel/callback"]
  post_logout_redirect_uris = ["https://${local.git_fqdn}/"]

  response_types = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types = [
    "OIDC_GRANT_TYPE_AUTHORIZATION_CODE",
    "OIDC_GRANT_TYPE_REFRESH_TOKEN",
  ]

  app_type         = "OIDC_APP_TYPE_WEB"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_BASIC"
  version          = "OIDC_VERSION_1_0"

  access_token_type           = "OIDC_TOKEN_TYPE_BEARER"
  access_token_role_assertion = false
  id_token_role_assertion     = false
  id_token_userinfo_assertion = false

  dev_mode = false
}

resource "zitadel_user_grant" "git_personal_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.personal.id
  project_id = zitadel_project.git.id
  role_keys  = []
}

# ─── Tailnet ingress ─────────────────────────────────────────────────────────
module "git_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "git"
  namespace            = kubernetes_namespace.git.metadata[0].name
  service_account_name = kubernetes_service_account.git.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.git_server_user
}

# ─── TLS cert + Vault KV (config + OIDC creds + opencode SSH key) ────────────
module "git_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "git"
  namespace            = kubernetes_namespace.git.metadata[0].name
  service_account_name = kubernetes_service_account.git.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = local.git_fqdn
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  config_secrets = {
    secret_key             = random_password.git_secret_key.result
    internal_token         = random_password.git_internal_token.result
    oauth2_jwt_secret      = random_password.git_oauth2_jwt.result
    lfs_jwt_secret         = random_password.git_lfs_jwt.result
    admin_password         = random_password.git_admin_password.result
    opencode_user_password = random_password.git_opencode_password.result
    personal_user_password = random_password.git_personal_password.result
    oidc_client_id         = zitadel_application_oidc.git.client_id
    oidc_client_secret     = zitadel_application_oidc.git.client_secret
  }

  providers = { acme = acme }
}

# ─── PVC ─────────────────────────────────────────────────────────────────────
resource "kubernetes_persistent_volume_claim" "git_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "git-data"
    namespace = kubernetes_namespace.git.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.git_storage_size
      }
    }
  }
  wait_until_bound = false
}

# ─── ConfigMaps (app.ini, nginx, bootstrap script, personal SSH pubkey) ──────
resource "kubernetes_config_map" "git_app_ini" {
  metadata {
    name      = "git-app-ini"
    namespace = kubernetes_namespace.git.metadata[0].name
  }
  data = {
    "app.ini" = local.git_app_ini
  }
}

resource "kubernetes_config_map" "git_nginx_config" {
  metadata {
    name      = "git-nginx-config"
    namespace = kubernetes_namespace.git.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/git.nginx.conf.tpl", {
      server_domain       = local.git_fqdn
      nginx_logging_block = local.nginx_logging_blocks["git"]
    })
  }
}

resource "kubernetes_config_map" "git_bootstrap_script" {
  metadata {
    name      = "git-bootstrap-script"
    namespace = kubernetes_namespace.git.metadata[0].name
  }
  data = {
    "forgejo-bootstrap.sh" = local.git_bootstrap_script
  }
}

# Personal user's SSH public key, sourced from var.git_personal_user_ssh_pub_key.
# Pub keys aren't secret — ConfigMap is appropriate. Mounted into the bootstrap
# Job at /etc/keys/personal.pub.
resource "kubernetes_config_map" "git_personal_pubkey" {
  metadata {
    name      = "git-personal-pubkey"
    namespace = kubernetes_namespace.git.metadata[0].name
  }
  data = {
    "personal.pub" = var.git_personal_user_ssh_pub_key
  }
}

# Opencode's TF-generated SSH public key. Mounted into the bootstrap Job at
# /etc/keys/opencode.pub. Sourced from tls_private_key.opencode_git_ssh in
# services/opencode.tf (cross-namespace, since pub keys aren't secret).
resource "kubernetes_config_map" "git_opencode_pubkey" {
  metadata {
    name      = "git-opencode-pubkey"
    namespace = kubernetes_namespace.git.metadata[0].name
  }
  data = {
    "opencode.pub" = trimspace(tls_private_key.opencode_git_ssh.public_key_openssh)
  }
}

# ─── NetworkPolicies ─────────────────────────────────────────────────────────
module "git_netpol_baseline" {
  source = "../templates/netpol-baseline"

  namespace    = kubernetes_namespace.git.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

# Cross-ns egress: git → oidc:443 (OIDC discovery + auth-code dance with
# Zitadel). Pod-scoped via matchExpressions so the rule covers BOTH the
# live forgejo pod (steady-state OIDC token exchange) AND the bootstrap
# Job pod (one-shot `forgejo admin auth add-oauth --auto-discover-url`
# fetches the discovery doc at add-time). Per `feedback_netpol_least_privilege`
# the labels are listed explicitly rather than open to the whole ns.
# Mirror ingress lives in services/zitadel-network.tf as oidc-from-git.
resource "kubernetes_network_policy" "git_to_oidc" {
  metadata {
    name      = "git-to-oidc"
    namespace = kubernetes_namespace.git.metadata[0].name
  }
  spec {
    pod_selector {
      match_expressions {
        key      = "app"
        operator = "In"
        values   = ["forgejo", "forgejo-bootstrap"]
      }
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

# Ingress: opencode → git:443 (web/REST) + git:2222 (SSH). Pod-scoped on
# both ends.
resource "kubernetes_network_policy" "git_from_opencode" {
  metadata {
    name      = "git-from-opencode"
    namespace = kubernetes_namespace.git.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = { app = "forgejo" }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "opencode"
          }
        }
        pod_selector {
          match_labels = { app = "opencode" }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
      ports {
        protocol = "TCP"
        port     = "2222"
      }
    }
  }
}

# ─── Deployment ──────────────────────────────────────────────────────────────
resource "kubernetes_deployment" "git" {
  metadata {
    name      = "git"
    namespace = kubernetes_namespace.git.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "forgejo" }
    }

    template {
      metadata {
        labels = { app = "forgejo" }
        annotations = {
          "app-ini-hash"                        = sha1(local.git_app_ini)
          "nginx-config-hash"                   = sha1(kubernetes_config_map.git_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "${module.git_tls_vault.config_secret_name},${module.git_tls_vault.tls_secret_name}"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.git.metadata[0].name

        # Pinned to the artemis GPU node (Phase-4 migration), colocated with
        # opencode so the clone/fetch/push path stays intra-node. node_selector
        # pulls it onto artemis; the toleration clears the gpu=true:NoSchedule
        # taint. The git-data PVC (SQLite DB + bare repos) is node-bound
        # local-path: it is re-provisioned fresh on artemis as part of the
        # migration and the bytes are rsync'd over from delphi. The bootstrap
        # Job is pinned identically below (it mounts the same PVC).
        # See docs/CLUSTER.md.
        node_selector = { node = "artemis" }
        toleration {
          key      = "gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        # In-cluster reach to Zitadel for OIDC discovery + token exchange.
        # Pin oidc.<tailnet> to the Zitadel ClusterIP so SNI + LE cert
        # validate without going through a tailscale egress sidecar.
        host_aliases {
          ip        = data.terraform_remote_state.vault_conf.outputs.zitadel_cluster_ip
          hostnames = ["${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"]
        }

        # Wait for Vault CSI secrets (admin password drives bootstrap).
        init_container {
          name              = "wait-for-secrets"
          image             = var.image_busybox
          image_pull_policy = "Always"
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

        # Rootless image runs as UID 1000; ensure data dir is writable.
        init_container {
          name              = "fix-permissions"
          image             = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            "chown -R 1000:1000 /var/lib/gitea"
          ]
          security_context {
            run_as_user = 0
          }
          volume_mount {
            name       = "git-data"
            mount_path = "/var/lib/gitea"
          }
        }

        # Seed app.ini at the rootless image's default writable path
        # (/var/lib/gitea/custom/conf/app.ini). The entrypoint's
        # `environment-to-ini` step rewrites this file in place every
        # start to merge FORGEJO__* env overrides, so the file AND its
        # parent directory must be writable by UID 1000. Runs as 1000 so
        # the mkdir-created dirs are owned correctly (parent /var/lib/gitea
        # is already chowned 1000:1000 by `fix-permissions` above).
        init_container {
          name              = "seed-app-ini"
          image             = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            "mkdir -p /var/lib/gitea/custom/conf && install -m 0640 /etc/gitea-tpl/app.ini /var/lib/gitea/custom/conf/app.ini"
          ]
          security_context {
            run_as_user  = 1000
            run_as_group = 1000
          }
          volume_mount {
            name       = "git-data"
            mount_path = "/var/lib/gitea"
          }
          volume_mount {
            name       = "git-app-ini"
            mount_path = "/etc/gitea-tpl"
            read_only  = true
          }
        }

        # ─── Forgejo ─────────────────────────────────────────────────────────
        container {
          name              = "forgejo"
          image             = var.image_forgejo
          image_pull_policy = "Always"

          port {
            container_port = 3000
            name           = "http"
          }
          port {
            container_port = 2222
            name           = "ssh"
          }

          # Forgejo 15 rootless defaults app.ini to the PVC location
          # (/var/lib/gitea/custom/conf/app.ini) — the entrypoint's
          # `environment-to-ini` step rewrites it on every start to merge
          # FORGEJO__* env overrides, so the file must be writable.
          # Seeded by the `seed-app-ini` init container above. Both
          # GITEA_* and FORGEJO_* prefixes set per upstream migration
          # guide.
          env {
            name  = "GITEA_APP_INI"
            value = "/var/lib/gitea/custom/conf/app.ini"
          }
          env {
            name  = "GITEA_WORK_DIR"
            value = "/var/lib/gitea"
          }
          env {
            name  = "FORGEJO_APP_INI"
            value = "/var/lib/gitea/custom/conf/app.ini"
          }
          env {
            name  = "FORGEJO_WORK_DIR"
            value = "/var/lib/gitea"
          }
          env {
            name  = "USER_UID"
            value = "1000"
          }
          env {
            name  = "USER_GID"
            value = "1000"
          }

          # Secrets via FORGEJO__<section>__<KEY> overrides (Forgejo's
          # documented env-override convention, takes precedence over file).
          env {
            name = "FORGEJO__security__SECRET_KEY"
            value_from {
              secret_key_ref {
                name = module.git_tls_vault.config_secret_name
                key  = "secret_key"
              }
            }
          }
          env {
            name = "FORGEJO__security__INTERNAL_TOKEN"
            value_from {
              secret_key_ref {
                name = module.git_tls_vault.config_secret_name
                key  = "internal_token"
              }
            }
          }
          env {
            name = "FORGEJO__oauth2__JWT_SECRET"
            value_from {
              secret_key_ref {
                name = module.git_tls_vault.config_secret_name
                key  = "oauth2_jwt_secret"
              }
            }
          }
          env {
            name = "FORGEJO__server__LFS_JWT_SECRET"
            value_from {
              secret_key_ref {
                name = module.git_tls_vault.config_secret_name
                key  = "lfs_jwt_secret"
              }
            }
          }

          volume_mount {
            name       = "git-data"
            mount_path = "/var/lib/gitea"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1000m", memory = "1Gi" }
          }

          liveness_probe {
            http_get {
              path = "/api/healthz"
              port = 3000
            }
            initial_delay_seconds = 60
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/api/healthz"
              port = 3000
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        # ─── Nginx (TLS termination + reverse proxy) ─────────────────────────
        container {
          name              = "nginx"
          image             = var.image_nginx
          image_pull_policy = "Always"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "git-tls"
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

        # ─── Tailscale ingress ───────────────────────────────────────────────
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
            value = module.git_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.git_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.git_domain
          }
          env {
            name  = "TS_EXTRA_ARGS"
            value = "--login-server=https://${data.terraform_remote_state.homelab.outputs.headscale_server_fqdn}"
          }
          env {
            name  = "TS_TAILSCALED_EXTRA_ARGS"
            value = "--port=41641"
          }
          # Advertise tailnet :443 → nginx :443 AND tailnet :22 → forgejo :2222.
          # `TS_SERVE_CONFIG` would be the modern path but isn't used elsewhere
          # in this repo; sticking with TS_DEST_IP-equivalent forwarding via
          # the pod itself works because the tailscale sidecar shares the pod
          # network namespace — :443 and :22 inbound terminate at this sidecar
          # but tailscaled's userspace proxy hands them off to the pod-local
          # listeners (nginx on :443; forgejo SSH on :2222). Wait — tailscaled
          # in TS_USERSPACE=false (kernel netstack) just IS the pod's network
          # listener for the tailnet IP; the kernel routes :443/:22 to whatever
          # listens locally on those ports. nginx binds :443 in this pod, but
          # nothing binds :22 — forgejo SSH is on :2222. So we DO need a port
          # rewrite. Set TS_SERVE_CONFIG to map tailnet :22 → 127.0.0.1:2222.
          env {
            name  = "TS_SERVE_CONFIG"
            value = "/etc/tailscale/serve-config.json"
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
          volume_mount {
            name       = "tailscale-serve-config"
            mount_path = "/etc/tailscale"
            read_only  = true
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "192Mi" }
          }
        }

        # ─── Volumes ─────────────────────────────────────────────────────────
        volume {
          name = "git-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.git_data.metadata[0].name
          }
        }
        volume {
          name = "git-app-ini"
          config_map {
            name = kubernetes_config_map.git_app_ini.metadata[0].name
          }
        }
        volume {
          name = "git-tls"
          secret { secret_name = module.git_tls_vault.tls_secret_name }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.git_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.git_tls_vault.spc_name
            }
          }
        }
        volume {
          name = "tailscale-serve-config"
          config_map {
            name = kubernetes_config_map.git_tailscale_serve.metadata[0].name
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
      }
    }
  }

  depends_on = [
    module.git_tls_vault,
    module.git_netpol_baseline,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

# Tailscale serve-config — ONLY claims tailnet :22, forwards to forgejo's
# in-pod SSH on :2222 (the rootless container can't bind <1024). :443 is
# intentionally left out so the nginx sidecar binds it directly on the
# pod's tailnet interface (kernel routes inbound tailnet :443 to whatever
# listens locally) — exactly the same pattern as grafana / rustical, no
# TS-side TLS termination needed since nginx already has the ACME cert.
#
# Per the tailscale containerboot docs, TS_SERVE_CONFIG ports are claimed
# exclusively by tailscaled; ports not listed remain available for other
# pod processes. Setting HTTPS=true on :443 here would conflict with
# nginx's bind.
resource "kubernetes_config_map" "git_tailscale_serve" {
  metadata {
    name      = "git-tailscale-serve"
    namespace = kubernetes_namespace.git.metadata[0].name
  }
  data = {
    "serve-config.json" = jsonencode({
      TCP = {
        "22" = { TCPForward = "127.0.0.1:2222" }
      }
    })
  }
}

# ─── Service ─────────────────────────────────────────────────────────────────
# ClusterIP exposes :443 (nginx) and :2222 (forgejo SSH) so opencode can
# dial either via host_aliases-pinned in-cluster routing. Per CLAUDE.md:
# no per-backend Tailscale egress sidecar; consumers reach this via
# `host_aliases git.<magic> = <ClusterIP>`.
resource "kubernetes_service" "git" {
  metadata {
    name      = "git"
    namespace = kubernetes_namespace.git.metadata[0].name
  }
  spec {
    selector = { app = "forgejo" }
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
    port {
      name        = "ssh-internal"
      port        = 2222
      target_port = 2222
    }
  }
}

# ─── Bootstrap Job ───────────────────────────────────────────────────────────
# Re-runs whenever the script or the OIDC client secret changes — name
# includes a hash so updates create a new Job rather than racing the
# "field is immutable" error on the existing one. Runs as the same UID as
# the Forgejo container so the offline `forgejo admin` CLI can read
# /var/lib/gitea/data/forgejo.db and /etc/gitea/app.ini.
resource "kubernetes_job_v1" "git_bootstrap" {
  metadata {
    name      = "git-bootstrap-${substr(sha1("${local.git_bootstrap_script}${zitadel_application_oidc.git.client_id}"), 0, 8)}"
    namespace = kubernetes_namespace.git.metadata[0].name
  }

  spec {
    backoff_limit              = 5
    ttl_seconds_after_finished = 86400

    template {
      metadata {
        labels = { app = "forgejo-bootstrap" }
      }
      spec {
        restart_policy       = "OnFailure"
        service_account_name = kubernetes_service_account.git.metadata[0].name

        # Must land on artemis alongside the live forgejo pod — it mounts the
        # same node-bound git-data PVC. Unpinned it could schedule on delphi
        # and hang Unschedulable against the artemis-bound PV. Mirrors the
        # Deployment's node pin above.
        node_selector = { node = "artemis" }
        toleration {
          key      = "gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        # Pin the git FQDN to the in-cluster Service ClusterIP so the
        # bootstrap container's curl validates the ACME cert (cert SAN is
        # ${local.git_fqdn}, not git.git.svc.cluster.local). Same pattern
        # opencode uses to reach forgejo.
        host_aliases {
          ip        = kubernetes_service.git.spec[0].cluster_ip
          hostnames = [local.git_fqdn]
        }
        # `forgejo admin auth add-oauth --auto-discover-url X` fetches X at
        # add-time (via goth's openidConnect.New → oidc.NewProvider HTTP
        # GET), so the bootstrap pod needs in-cluster reach to Zitadel,
        # not just the live forgejo pod. Pin oidc.<magic> to the Zitadel
        # ClusterIP so the discovery TLS cert validates.
        host_aliases {
          ip        = data.terraform_remote_state.vault_conf.outputs.zitadel_cluster_ip
          hostnames = [local.git_zitadel_fqdn]
        }

        container {
          name              = "bootstrap"
          image             = var.image_forgejo
          image_pull_policy = "Always"

          # `forgejo admin` offline CLI reads /etc/gitea/app.ini and the
          # SQLite DB at /var/lib/gitea/data/forgejo.db. Must run as UID
          # 1000 to read both.
          security_context {
            run_as_user  = 1000
            run_as_group = 1000
          }

          command = ["/bin/sh", "/etc/bootstrap/forgejo-bootstrap.sh"]

          env {
            name  = "GITEA_APP_INI"
            value = "/var/lib/gitea/custom/conf/app.ini"
          }
          env {
            name  = "GITEA_WORK_DIR"
            value = "/var/lib/gitea"
          }
          env {
            name  = "FORGEJO_APP_INI"
            value = "/var/lib/gitea/custom/conf/app.ini"
          }
          env {
            name  = "FORGEJO_WORK_DIR"
            value = "/var/lib/gitea"
          }
          env {
            name = "ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.git_tls_vault.config_secret_name
                key  = "admin_password"
              }
            }
          }
          env {
            name = "OIDC_CLIENT_ID"
            value_from {
              secret_key_ref {
                name = module.git_tls_vault.config_secret_name
                key  = "oidc_client_id"
              }
            }
          }
          env {
            name = "OIDC_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = module.git_tls_vault.config_secret_name
                key  = "oidc_client_secret"
              }
            }
          }
          env {
            name = "OPENCODE_USER_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.git_tls_vault.config_secret_name
                key  = "opencode_user_password"
              }
            }
          }
          env {
            name = "PERSONAL_USER_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.git_tls_vault.config_secret_name
                key  = "personal_user_password"
              }
            }
          }

          volume_mount {
            name       = "git-data"
            mount_path = "/var/lib/gitea"
          }
          volume_mount {
            name       = "bootstrap-script"
            mount_path = "/etc/bootstrap"
            read_only  = true
          }
          volume_mount {
            name       = "personal-pubkey"
            mount_path = "/etc/keys/personal.pub"
            sub_path   = "personal.pub"
            read_only  = true
          }
          volume_mount {
            name       = "opencode-pubkey"
            mount_path = "/etc/keys/opencode.pub"
            sub_path   = "opencode.pub"
            read_only  = true
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        volume {
          name = "git-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.git_data.metadata[0].name
          }
        }
        volume {
          name = "bootstrap-script"
          config_map {
            name         = kubernetes_config_map.git_bootstrap_script.metadata[0].name
            default_mode = "0555"
          }
        }
        volume {
          name = "personal-pubkey"
          config_map {
            name = kubernetes_config_map.git_personal_pubkey.metadata[0].name
          }
        }
        volume {
          name = "opencode-pubkey"
          config_map {
            name = kubernetes_config_map.git_opencode_pubkey.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.git_tls_vault.spc_name
            }
          }
        }
      }
    }
  }

  wait_for_completion = false

  depends_on = [
    kubernetes_deployment.git,
  ]
}
