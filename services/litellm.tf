resource "kubernetes_namespace" "litellm" {
  metadata {
    name = "litellm"
  }
}

resource "kubernetes_service_account" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }
  automount_service_account_token = false
}

resource "aws_iam_user" "litellm_bedrock" {
  name = "litellm-bedrock"
}

resource "aws_iam_user_policy" "litellm_bedrock" {
  name = "litellm-bedrock"
  user = aws_iam_user.litellm_bedrock.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:Converse",
          "bedrock:ConverseStream"
        ]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/*",
          "arn:aws:bedrock:*:*:inference-profile/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:ListFoundationModels",
          "bedrock:GetFoundationModel",
          "aws-marketplace:ViewSubscriptions"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_access_key" "litellm_bedrock" {
  user = aws_iam_user.litellm_bedrock.name
}

resource "random_password" "litellm_master_key" {
  length  = 32
  special = false
}

resource "random_password" "litellm_db" {
  length  = 24
  special = false
}

# Break-glass local UI login. SSO is the normal path; this is the fallback
# if Zitadel is down. Username is fixed as "admin" (LiteLLM treats UI_USERNAME
# as the login name; it has no relationship to a Zitadel identity).
#
# Rotation: terraform apply -replace=random_password.litellm_ui_password
resource "random_password" "litellm_ui_password" {
  length  = 32
  special = false
}

# ─── Zitadel project + role + OIDC application + per-user grant ──────────────
#
# Per memory `feedback_zitadel_one_project_per_service`, litellm gets its own
# project. project_role_check=true so Zitadel itself rejects token issuance
# for users without a grant — only the personal user can ever sign in.
# Inside LiteLLM, ui_access_mode=admin_only + PROXY_ADMIN_ID gate the UI to
# the same user. ALLOWED_EMAIL_DOMAINS deliberately not set: the OIDC email
# claim is the user's contact email, not the magic-domain login (see memory
# feedback_zitadel_email_claim_override).
resource "zitadel_project" "litellm" {
  name   = "litellm"
  org_id = data.zitadel_organizations.homelab.ids[0]

  project_role_assertion   = true
  project_role_check       = true
  has_project_check        = true
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"
}

resource "zitadel_project_role" "litellm_admin" {
  org_id       = data.zitadel_organizations.homelab.ids[0]
  project_id   = zitadel_project.litellm.id
  role_key     = "admin"
  display_name = "LiteLLM admin"
}

resource "zitadel_application_oidc" "litellm" {
  name       = "LiteLLM"
  org_id     = data.zitadel_organizations.homelab.ids[0]
  project_id = zitadel_project.litellm.id

  redirect_uris             = ["https://${var.litellm_domain}.${local.magic_fqdn_suffix}/sso/callback"]
  post_logout_redirect_uris = ["https://${var.litellm_domain}.${local.magic_fqdn_suffix}/"]

  response_types   = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types      = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"]
  app_type         = "OIDC_APP_TYPE_WEB"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_BASIC"
  dev_mode         = false
}

resource "zitadel_user_grant" "litellm_personal_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.personal.id
  project_id = zitadel_project.litellm.id
  role_keys  = [zitadel_project_role.litellm_admin.role_key]
}

module "litellm_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "litellm"
  namespace            = kubernetes_namespace.litellm.metadata[0].name
  service_account_name = kubernetes_service_account.litellm.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.litellm_server_user
}

module "litellm_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "litellm"
  namespace            = kubernetes_namespace.litellm.metadata[0].name
  service_account_name = kubernetes_service_account.litellm.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = "${var.litellm_domain}.${local.magic_fqdn_suffix}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  config_secrets = {
    master_key            = "sk-${random_password.litellm_master_key.result}"
    db_password           = random_password.litellm_db.result
    database_url          = "postgresql://litellm:${random_password.litellm_db.result}@litellm-postgres:5432/litellm"
    aws_access_key_id     = aws_iam_access_key.litellm_bedrock.id
    aws_secret_access_key = aws_iam_access_key.litellm_bedrock.secret
    oidc_client_id        = zitadel_application_oidc.litellm.client_id
    oidc_client_secret    = zitadel_application_oidc.litellm.client_secret
    ui_password           = random_password.litellm_ui_password.result
  }

  providers = { acme = acme }
}

resource "kubernetes_persistent_volume_claim" "litellm_postgres_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "litellm-postgres-data"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = "5Gi"
      }
    }
  }
  wait_until_bound = false
}

locals {
  # In-cluster URL LiteLLM uses to reach the local llama-swap inference
  # service (services/llm.tf). Pinned to the llm Service ClusterIP via
  # host_aliases on the litellm Deployment below, so SNI + the real ACME
  # cert validate without a Tailscale egress sidecar
  # (feedback_no_egress_only_ts_sidecars).
  llm_inference_base = "https://${var.llm_domain}.${local.magic_fqdn_suffix}/v1"

  litellm_config_yaml = yamlencode({
    model_list = [
      for alias, cfg in var.llm_models : {
        model_name = alias
        litellm_params = { for k, v in {
          # llamaswap → local llama-swap as an OpenAI-compatible upstream:
          # model becomes openai/<llama-swap key> and api_base points at the
          # in-cluster llm endpoint. bedrock/others keep provider/model_id.
          model    = cfg.provider == "llamaswap" ? "openai/${cfg.model_id}" : "${cfg.provider}/${cfg.model_id}"
          api_base = cfg.provider == "llamaswap" ? local.llm_inference_base : null
          # LiteLLM's openai provider requires some api_key even though
          # llama-swap currently has no auth; a placeholder satisfies it.
          api_key         = cfg.provider == "llamaswap" ? "sk-noauth" : null
          aws_region_name = cfg.provider == "bedrock" ? coalesce(cfg.aws_region, var.aws_region) : null
          max_tokens      = cfg.max_tokens
          # fake_stream: when true, LiteLLM does a non-streaming request
          # upstream and re-emits chunks downstream. Set per-model in
          # var.llm_models for vLLM streaming-only parser bugs (e.g.
          # Qwen3-Next + hermes parser dropping tool_calls into raw
          # `content`, vllm#31871). Omitted from the rendered config
          # when null so models that should stream normally are untouched.
          fake_stream = cfg.fake_stream
          cache_control_injection_points = cfg.provider == "bedrock" && can(regex("anthropic", cfg.model_id)) ? [
            { location = "message", role = "system" },
            { location = "message", index = -2 },
            { location = "message", index = -1 },
          ] : null
        } : k => v if v != null }
        model_info = { for k, v in {
          input_cost_per_token        = cfg.input_cost_per_token
          output_cost_per_token       = cfg.output_cost_per_token
          cache_read_input_token_cost = cfg.cache_read_input_token_cost
        } : k => v if v != null }
      }
    ]
    litellm_settings = {
      default_internal_user_params = {
        max_budget = var.litellm_default_user_max_budget
      }
      # Silently drop provider-unsupported params (e.g. tool_choice on Llama4
      # Maverick via Bedrock) instead of 400-ing the request.
      drop_params = true
    }
    # admin_only restricts the UI to proxy_admin / proxy_admin_viewer roles.
    # Combined with PROXY_ADMIN_ID env (set to zitadel_human_user.personal.id),
    # this means only the personal user can ever load the UI even if Zitadel
    # somehow issued a token to a non-granted user.
    general_settings = {
      ui_access_mode = "admin_only"
      # Persist request/response bodies in the spend-logs table so the UI
      # can show finish_reason, the actual prompt sent, and the model's
      # raw response. Off by default; enabled for debugging opencode
      # truncation issues. Note: this stores full prompts (and any embedded
      # secrets) in the LiteLLM Postgres — Vault CSI doesn't apply.
      store_prompts_in_spend_logs = true
    }
  })
}

resource "kubernetes_config_map" "litellm_config" {
  metadata {
    name      = "litellm-config"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }
  data = {
    "config.yaml" = local.litellm_config_yaml
  }
}

resource "kubernetes_config_map" "litellm_nginx_config" {
  metadata {
    name      = "litellm-nginx-config"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/litellm.nginx.conf.tpl", {
      server_domain       = "${var.litellm_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
      nginx_logging_block = local.nginx_logging_blocks["litellm"]
    })
  }
}

resource "kubernetes_deployment" "litellm_postgres" {
  metadata {
    name      = "litellm-postgres"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "litellm-postgres"
      }
    }

    template {
      metadata {
        labels = {
          app = "litellm-postgres"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.litellm.metadata[0].name

        # Pinned to the artemis GPU node (Phase-4 migration). node_selector pulls
        # it onto artemis; the toleration clears the gpu=true:NoSchedule taint.
        # The litellm-postgres-data PVC is re-provisioned fresh on artemis as
        # part of the migration (local-path PVs are node-bound) and restored from
        # a pg_dump. See docs/CLUSTER.md.
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
              secret_file = "db_password"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        container {
          name  = "postgres"
          image = var.image_litellm_postgres
          image_pull_policy = "Always"

          env {
            name  = "POSTGRES_DB"
            value = "litellm"
          }
          env {
            name  = "POSTGRES_USER"
            value = "litellm"
          }
          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.litellm_tls_vault.config_secret_name
                key  = "db_password"
              }
            }
          }

          port {
            container_port = 5432
          }

          volume_mount {
            name       = "litellm-postgres-data"
            mount_path = "/var/lib/postgresql/data"
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
            exec {
              command = ["pg_isready", "-U", "litellm", "-d", "litellm"]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          readiness_probe {
            exec {
              command = ["pg_isready", "-U", "litellm", "-d", "litellm"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }

        volume {
          name = "litellm-postgres-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.litellm_postgres_data.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.litellm_tls_vault.spc_name
            }
          }
        }
      }
    }
  }

  depends_on = [
    module.litellm_tls_vault,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "litellm_postgres" {
  metadata {
    name      = "litellm-postgres"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }
  spec {
    selector = {
      app = "litellm-postgres"
    }
    port {
      port        = 5432
      target_port = 5432
    }
  }
}

resource "kubernetes_deployment" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "litellm"
      }
    }

    template {
      metadata {
        labels = {
          app = "litellm"
        }
        annotations = {
          "config-hash"                         = sha1(kubernetes_config_map.litellm_config.data["config.yaml"])
          "nginx-config-hash"                   = sha1(kubernetes_config_map.litellm_nginx_config.data["nginx.conf"])
          "secret.reloader.stakater.com/reload" = "litellm-secrets,litellm-tls"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.litellm.metadata[0].name

        # Pinned to the artemis GPU node (Phase-4 migration) — co-located with
        # litellm-postgres and near the future local Qwen endpoint. node_selector
        # pulls it onto artemis; the toleration clears the gpu=true:NoSchedule
        # taint. The proxy has no PVC, so it moves freely. See
        # docs/CLUSTER.md.
        node_selector = { node = "artemis" }
        toleration {
          key      = "gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        # Pin oidc.<tailnet> to the Zitadel ClusterIP so SSO discovery,
        # token exchange, and userinfo all hit the in-cluster Service via
        # nginx-correct SNI without an egress Tailscale sidecar
        # (memory: feedback_no_egress_only_ts_sidecars).
        host_aliases {
          ip        = data.terraform_remote_state.vault_conf.outputs.zitadel_cluster_ip
          hostnames = ["${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"]
        }

        # Pin llm.<tailnet> to the local llama-swap Service ClusterIP so
        # LiteLLM's openai-compatible upstream calls reach the in-cluster `llm`
        # endpoint with correct SNI + cert (feedback_no_egress_only_ts_sidecars).
        host_aliases {
          ip        = kubernetes_service.llm.spec[0].cluster_ip
          hostnames = ["${var.llm_domain}.${local.magic_fqdn_suffix}"]
        }

        init_container {
          name  = "wait-for-secrets"
          image = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              # Gate on oidc_client_id — written in the same Vault round-trip
              # as master_key but lands later (last-added field), so a present
              # client_id implies the rest of the secret is present too.
              secret_file = "oidc_client_id"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # LiteLLM Proxy
        container {
          name  = "litellm"
          image = var.image_litellm
          image_pull_policy = "Always"

          args = ["--config", "/etc/litellm/config.yaml", "--port", "4000"]

          port {
            container_port = 4000
            name           = "http"
          }

          env {
            name = "LITELLM_MASTER_KEY"
            value_from {
              secret_key_ref {
                name = module.litellm_tls_vault.config_secret_name
                key  = "master_key"
              }
            }
          }

          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = module.litellm_tls_vault.config_secret_name
                key  = "database_url"
              }
            }
          }

          env {
            name = "AWS_ACCESS_KEY_ID"
            value_from {
              secret_key_ref {
                name = module.litellm_tls_vault.config_secret_name
                key  = "aws_access_key_id"
              }
            }
          }

          env {
            name = "AWS_SECRET_ACCESS_KEY"
            value_from {
              secret_key_ref {
                name = module.litellm_tls_vault.config_secret_name
                key  = "aws_secret_access_key"
              }
            }
          }

          env {
            name  = "AWS_DEFAULT_REGION"
            value = var.aws_region
          }

          env {
            name  = "LITELLM_LOG"
            value = "WARNING"
          }

          # ─── OIDC SSO via Zitadel (FOSS path, "GENERIC" provider) ────────
          #
          # User flow: `https://litellm.<magic>/ui` → 302 to Zitadel → log in
          # as the personal user → 302 back to /sso/callback → land in the
          # admin UI as proxy_admin.
          #
          # Authz layers (defence in depth):
          #   1. Zitadel project_role_check=true + lone user_grant: only the
          #      personal user has a grant, all others get 403 from Zitadel
          #      before redirect-back.
          #   2. ALLOWED_EMAIL_DOMAINS: secondary email-domain wall.
          #   3. ui_access_mode=admin_only (set in config.yaml): UI requires
          #      proxy_admin role.
          #   4. PROXY_ADMIN_ID: pre-baked to the Zitadel user's `sub` so the
          #      first SSO login lands as proxy_admin with no manual bootstrap.
          #
          # GENERIC_USER_ID_ATTRIBUTE=sub (vs default `preferred_username`):
          # `sub` is Zitadel's immutable numeric ID, survives username changes,
          # and matches zitadel_human_user.personal.id at TF time.
          #
          # NOTE: SSO on FOSS LiteLLM is "free for ≤5 users" since v1.76.0 but
          # has a known LITELLM_LICENSE-gate regression (BerriAI/litellm#16866)
          # on some tags. var.image_litellm is pinned to a known-good stable
          # release (see services/variables.tf).
          env {
            name  = "PROXY_BASE_URL"
            value = "https://${var.litellm_domain}.${local.magic_fqdn_suffix}"
          }
          env {
            name  = "GENERIC_AUTHORIZATION_ENDPOINT"
            value = "https://${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}/oauth/v2/authorize"
          }
          env {
            name  = "GENERIC_TOKEN_ENDPOINT"
            value = "https://${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}/oauth/v2/token"
          }
          env {
            name  = "GENERIC_USERINFO_ENDPOINT"
            value = "https://${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}/oidc/v1/userinfo"
          }
          env {
            name  = "GENERIC_SCOPE"
            value = "openid email profile"
          }
          env {
            name  = "GENERIC_USER_ID_ATTRIBUTE"
            value = "sub"
          }
          env {
            name  = "GENERIC_USER_EMAIL_ATTRIBUTE"
            value = "email"
          }
          env {
            name  = "GENERIC_USER_DISPLAY_NAME_ATTRIBUTE"
            value = "name"
          }
          env {
            name  = "GENERIC_USER_FIRST_NAME_ATTRIBUTE"
            value = "given_name"
          }
          env {
            name  = "GENERIC_USER_LAST_NAME_ATTRIBUTE"
            value = "family_name"
          }
          # Confidential web app (auth_method_type=BASIC on the Zitadel side);
          # PKCE is for public clients.
          env {
            name  = "GENERIC_CLIENT_USE_PKCE"
            value = "false"
          }
          env {
            name = "GENERIC_CLIENT_ID"
            value_from {
              secret_key_ref {
                name = module.litellm_tls_vault.config_secret_name
                key  = "oidc_client_id"
              }
            }
          }
          env {
            name = "GENERIC_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = module.litellm_tls_vault.config_secret_name
                key  = "oidc_client_secret"
              }
            }
          }
          env {
            name  = "PROXY_ADMIN_ID"
            value = zitadel_human_user.personal.id
          }
          # Skip the "Single Sign-On is enabled" intermediate page; jump
          # straight to the Zitadel auth flow when /ui hits the login page.
          env {
            name  = "AUTO_REDIRECT_UI_LOGIN_TO_SSO"
            value = "true"
          }
          # No ALLOWED_EMAIL_DOMAINS: the OIDC email claim is the user's
          # contact email (var.zitadel_personal_user.email, e.g. personal email),
          # which doesn't match the magic domain (magic). Filtering by
          # domain here would block the legitimate user. Access control lives
          # one layer up at zitadel_project.litellm.project_role_check=true,
          # which only the personal user has a grant for. See memory
          # feedback_zitadel_email_claim_override for the rationale.
          # Break-glass local UI login. Independent of SSO; usable when
          # Zitadel is down. Username is "admin"; password rotates with
          # `terraform apply -replace=random_password.litellm_ui_password`.
          env {
            name  = "UI_USERNAME"
            value = "admin"
          }
          env {
            name = "UI_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.litellm_tls_vault.config_secret_name
                key  = "ui_password"
              }
            }
          }

          volume_mount {
            name       = "litellm-config"
            mount_path = "/etc/litellm/config.yaml"
            sub_path   = "config.yaml"
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "1Gi"
            }
            limits = {
              cpu    = "500m"
              memory = "2Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health/liveliness"
              port = 4000
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 10
          }

          readiness_probe {
            http_get {
              path = "/health/readiness"
              port = 4000
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        # Nginx
        container {
          name  = "litellm-nginx"
          image = var.image_nginx
          image_pull_policy = "Always"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "litellm-tls"
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
              memory = "256Mi"
            }
          }
        }

        # Tailscale
        container {
          name  = "litellm-tailscale"
          image = var.image_tailscale
          image_pull_policy = "Always"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.litellm_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.litellm_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.litellm_domain
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

        # Volumes
        volume {
          name = "litellm-config"
          config_map {
            name = kubernetes_config_map.litellm_config.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.litellm_tls_vault.spc_name
            }
          }
        }
        volume {
          name = "litellm-tls"
          secret {
            secret_name = module.litellm_tls_vault.tls_secret_name
          }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.litellm_nginx_config.metadata[0].name
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
    module.litellm_tls_vault,
    kubernetes_deployment.litellm_postgres,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }
  spec {
    selector = {
      app = "litellm"
    }
    port {
      name        = "litellm"
      port        = 4000
      target_port = 4000
    }
    # nginx sidecar terminates TLS with the litellm.<hs>.<magic> cert.
    # In-cluster callers using host_aliases reach :443 here so SNI + cert
    # validation continue to work after egress-only Tailscale sidecars
    # (mcp-litellm, thunderbolt-backend) are removed.
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
  }
}

# NetworkPolicies for the `litellm` namespace.
#
# Hosts: litellm + litellm-postgres. Both reach each other intra-ns.
# litellm proxies to upstream providers (Bedrock, DeepInfra) via the
# public internet — covered by the baseline's internet egress.

module "litellm_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.litellm.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

# Cross-ns ingress: thunderbolt-backend → litellm:443. Replaces the
# Tailscale-routed egress that thunderbolt-backend used to do via its
# now-removed sidecar (env THUNDERBOLT_INFERENCE_URL). nginx terminates
# TLS with the litellm.<hs>.<magic> cert; ClusterIP DNAT preserves SNI.
resource "kubernetes_network_policy" "litellm_from_thunderbolt" {
  metadata {
    name      = "litellm-from-thunderbolt"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }

  spec {
    pod_selector { match_labels = { app = "litellm" } }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.thunderbolt.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "thunderbolt-backend" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

# Cross-ns ingress: mcp-litellm → litellm:443. Replaces the Tailscale-routed
# egress that the mcp-litellm pod used to do via its now-removed sidecar
# (env LITELLM_BASE_URL). The mcp namespace has no baseline NetworkPolicy so
# no source-side egress allow is needed.
resource "kubernetes_network_policy" "litellm_from_mcp_litellm" {
  metadata {
    name      = "litellm-from-mcp-litellm"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }

  spec {
    pod_selector { match_labels = { app = "litellm" } }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.mcp.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "mcp-litellm" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

# Cross-ns egress: litellm → oidc:443. Server-side OIDC SSO callback
# (litellm.tf env GENERIC_TOKEN_ENDPOINT, GENERIC_USERINFO_ENDPOINT) does
# the code-for-token exchange + userinfo fetch against Zitadel. Mirror
# ingress lives in services/zitadel-network.tf as oidc-from-litellm.
resource "kubernetes_network_policy" "litellm_to_oidc" {
  metadata {
    name      = "litellm-to-oidc"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = { app = "litellm" }
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

# Cross-ns egress: litellm → llm (local llama-swap). LiteLLM proxies
# llamaswap-provider models to the in-cluster `llm` endpoint over :443
# (nginx sidecar terminates TLS; pinned via host_aliases above). Ingress
# allow lives on the receiving side as `llm-from-litellm` in services/llm.tf.
resource "kubernetes_network_policy" "litellm_to_llm" {
  metadata {
    name      = "litellm-to-llm"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = { app = "litellm" }
    }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.llm.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "llm" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

# Cross-ns ingress: opencode → litellm:443. opencode reaches LiteLLM via
# host_aliases pinning litellm.<hs>.<magic> to the litellm Service ClusterIP
# (per feedback_no_egress_only_ts_sidecars). Source-side egress allow
# lives in services/opencode-network.tf as opencode-to-litellm.
resource "kubernetes_network_policy" "litellm_from_opencode" {
  metadata {
    name      = "litellm-from-opencode"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }

  spec {
    pod_selector { match_labels = { app = "litellm" } }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.opencode.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "opencode" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

# Cross-ns ingress: navidrome-ingest → litellm:443. The worker tags new
# dropzone files via LiteLLM (filename NER). Source-side egress allow
# lives in services/navidrome-ingest-network.tf.
resource "kubernetes_network_policy" "litellm_from_navidrome_ingest" {
  metadata {
    name      = "litellm-from-navidrome-ingest"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }

  spec {
    pod_selector { match_labels = { app = "litellm" } }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.navidrome.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "navidrome-ingest" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}
