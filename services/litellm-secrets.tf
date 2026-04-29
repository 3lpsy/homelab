
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

resource "kubernetes_secret" "litellm_tailscale_state" {
  metadata {
    name      = "litellm-tailscale-state"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }
  type = "Opaque"

  lifecycle {
    ignore_changes = [data, type]
  }
}

resource "kubernetes_role" "litellm_tailscale" {
  metadata {
    name      = "litellm-tailscale"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["litellm-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "litellm_tailscale" {
  metadata {
    name      = "litellm-tailscale"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.litellm_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.litellm.metadata[0].name
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }
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

resource "headscale_pre_auth_key" "litellm" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.litellm_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "litellm_tailscale_auth" {
  metadata {
    name      = "litellm-tailscale-auth"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.litellm.key
  }
}

module "litellm-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.litellm_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "vault_kv_secret_v2" "litellm_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "litellm/config"
  data_json = jsonencode({
    master_key            = "sk-${random_password.litellm_master_key.result}"
    db_password           = random_password.litellm_db.result
    database_url          = "postgresql://litellm:${random_password.litellm_db.result}@litellm-postgres:5432/litellm"
    aws_access_key_id     = aws_iam_access_key.litellm_bedrock.id
    aws_secret_access_key = aws_iam_access_key.litellm_bedrock.secret
    deepinfra_api_key     = var.deepinfra_api_key
  })
}

resource "vault_kv_secret_v2" "litellm_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "litellm/tls"
  data_json = jsonencode({
    fullchain_pem = module.litellm-tls.fullchain_pem
    privkey_pem   = module.litellm-tls.privkey_pem
  })

  # tls-rotator (services/tls-rotator.tf) owns rotation post-bootstrap.
  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "vault_policy" "litellm" {
  name = "litellm-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/litellm/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "litellm" {
  backend                          = "kubernetes"
  role_name                        = "litellm"
  bound_service_account_names      = ["litellm"]
  bound_service_account_namespaces = ["litellm"]
  token_policies                   = [vault_policy.litellm.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "litellm_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-litellm"
      namespace = kubernetes_namespace.litellm.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "litellm-secrets"
          type       = "Opaque"
          data = [
            { objectName = "litellm_master_key", key = "master_key" },
            { objectName = "litellm_db_password", key = "db_password" },
            { objectName = "litellm_database_url", key = "database_url" },
            { objectName = "litellm_aws_access_key_id", key = "aws_access_key_id" },
            { objectName = "litellm_aws_secret_access_key", key = "aws_secret_access_key" },
            { objectName = "litellm_deepinfra_api_key", key = "deepinfra_api_key" },
          ]
        },
        {
          secretName = "litellm-tls"
          type       = "kubernetes.io/tls"
          data = [
            { objectName = "litellm_tls_crt", key = "tls.crt" },
            { objectName = "litellm_tls_key", key = "tls.key" },
          ]
        }
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "litellm"
        objects = yamlencode([
          {
            objectName = "litellm_master_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/litellm/config"
            secretKey  = "master_key"
          },
          {
            objectName = "litellm_db_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/litellm/config"
            secretKey  = "db_password"
          },
          {
            objectName = "litellm_database_url"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/litellm/config"
            secretKey  = "database_url"
          },
          {
            objectName = "litellm_aws_access_key_id"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/litellm/config"
            secretKey  = "aws_access_key_id"
          },
          {
            objectName = "litellm_aws_secret_access_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/litellm/config"
            secretKey  = "aws_secret_access_key"
          },
          {
            objectName = "litellm_deepinfra_api_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/litellm/config"
            secretKey  = "deepinfra_api_key"
          },
          {
            objectName = "litellm_tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/litellm/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "litellm_tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/litellm/tls"
            secretKey  = "privkey_pem"
          },
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.litellm,
    vault_kubernetes_auth_backend_role.litellm,
    vault_kv_secret_v2.litellm_config,
    vault_kv_secret_v2.litellm_tls
  ]
}

