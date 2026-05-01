terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
    acme = {
      source                = "vancluever/acme"
      version               = "~> 2.0"
      configuration_aliases = [acme]
    }
  }
}

locals {
  vault_path         = coalesce(var.vault_kv_path, var.service_name)
  config_path        = "${local.vault_path}/config"
  tls_path           = "${local.vault_path}/tls"
  config_secret_name = coalesce(var.config_secret_name, "${var.service_name}-secrets")
  tls_secret_name    = coalesce(var.tls_secret_name, "${var.service_name}-tls")
  spc_name           = coalesce(var.spc_name, "vault-${var.service_name}")
  policy_name        = coalesce(var.policy_name, "${var.service_name}-policy")
  role_name          = coalesce(var.role_name, var.service_name)

  config_keys = keys(var.config_secrets)

  # Vault config write happens only when config_secrets has entries —
  # extra_config_keys reference Vault paths owned by sibling services.
  has_config_kv_write = length(local.config_keys) > 0

  # The k8s config secret (<svc>-secrets) gets created when EITHER
  # config_secrets has entries or extra_config_keys does.
  has_config_secret = local.has_config_kv_write || length(var.extra_config_keys) > 0

  config_so_list = local.has_config_secret ? [{
    secretName = local.config_secret_name
    type       = "Opaque"
    data = concat(
      [for k in local.config_keys : { objectName = k, key = k }],
      [for e in var.extra_config_keys : { objectName = e.object_name, key = e.object_name }],
    )
  }] : []

  extra_config_object_entries = [
    for e in var.extra_config_keys : {
      objectName = e.object_name
      secretPath = "${var.vault_kv_mount}/data/${e.vault_path}"
      secretKey  = e.vault_key
    }
  ]

  extra_so_list = [
    for e in var.extra_secret_objects : {
      secretName = e.secret_name
      type       = e.type
      data       = [for i in e.items : { objectName = i.object_name, key = i.k8s_key }]
    }
  ]

  extra_objects_flat = flatten([
    for e in var.extra_secret_objects : [
      for i in e.items : {
        objectName = i.object_name
        secretPath = "${var.vault_kv_mount}/data/${i.vault_path}"
        secretKey  = i.vault_key
      }
    ]
  ])
}

module "tls" {
  source                = "../infra-tls"
  account_key_pem       = var.acme_account_key_pem
  server_domain         = var.tls_domain
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "vault_kv_secret_v2" "config" {
  count = local.has_config_kv_write ? 1 : 0

  mount     = var.vault_kv_mount
  name      = local.config_path
  data_json = jsonencode(var.config_secrets)
}

resource "vault_kv_secret_v2" "tls" {
  mount = var.vault_kv_mount
  name  = local.tls_path
  data_json = jsonencode({
    fullchain_pem = module.tls.fullchain_pem
    privkey_pem   = module.tls.privkey_pem
  })

  # tls-rotator (services/tls-rotator.tf) owns rotation post-bootstrap.
  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "vault_policy" "this" {
  count = var.manage_vault_auth ? 1 : 0

  name = local.policy_name

  policy = <<EOT
path "${var.vault_kv_mount}/data/${local.vault_path}/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "this" {
  count = var.manage_vault_auth ? 1 : 0

  backend                          = "kubernetes"
  role_name                        = local.role_name
  bound_service_account_names      = [var.service_account_name]
  bound_service_account_namespaces = [var.namespace]
  token_policies                   = [vault_policy.this[0].name]
  token_ttl                        = var.token_ttl
}

resource "kubernetes_manifest" "spc" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = local.spc_name
      namespace = var.namespace
    }
    spec = {
      provider = "vault"
      secretObjects = concat(local.config_so_list, [
        {
          secretName = local.tls_secret_name
          type       = "kubernetes.io/tls"
          data = [
            { objectName = "tls_crt", key = "tls.crt" },
            { objectName = "tls_key", key = "tls.key" }
          ]
        }
      ], local.extra_so_list)
      parameters = {
        vaultAddress = var.vault_address
        roleName     = local.role_name
        objects = yamlencode(concat(
          [
            for k in local.config_keys : {
              objectName = k
              secretPath = "${var.vault_kv_mount}/data/${local.config_path}"
              secretKey  = k
            }
          ],
          [
            {
              objectName = "tls_crt"
              secretPath = "${var.vault_kv_mount}/data/${local.tls_path}"
              secretKey  = "fullchain_pem"
            },
            {
              objectName = "tls_key"
              secretPath = "${var.vault_kv_mount}/data/${local.tls_path}"
              secretKey  = "privkey_pem"
            }
          ],
          local.extra_config_object_entries,
          local.extra_objects_flat,
        ))
      }
    }
  }

  depends_on = [
    vault_kubernetes_auth_backend_role.this,
    vault_kv_secret_v2.config,
    vault_kv_secret_v2.tls,
    vault_policy.this,
  ]
}

# When config_secrets is empty, the SPC's secretObjects list omits the
# <svc>-secrets entry and no Vault config write happens. The Vault policy
# still grants read on <vault_kv_path>/* so a future config addition only
# needs the var to be set; no extra perms.

