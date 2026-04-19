module "mcp-searxng-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = local.mcp_searxng_fqdn
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "random_password" "mcp_searxng_api_keys" {
  count   = var.mcp_searxng_api_key_count
  length  = 48
  special = false
}

locals {
  mcp_searxng_api_keys_csv = join(",", [for p in random_password.mcp_searxng_api_keys : p.result])
}

resource "vault_kv_secret_v2" "mcp_searxng_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "mcp/mcp-searxng/tls"
  data_json = jsonencode({
    fullchain_pem = module.mcp-searxng-tls.fullchain_pem
    privkey_pem   = module.mcp-searxng-tls.privkey_pem
  })
}

resource "vault_kv_secret_v2" "mcp_searxng_auth" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "mcp/mcp-searxng/auth"
  data_json = jsonencode(merge(
    { api_keys_csv = local.mcp_searxng_api_keys_csv },
    { for i, p in random_password.mcp_searxng_api_keys : "api_key_${i}" => p.result },
  ))
}

resource "kubernetes_manifest" "mcp_searxng_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-mcp-searxng"
      namespace = kubernetes_namespace.mcp.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "mcp-searxng-tls"
          type       = "kubernetes.io/tls"
          data = [
            { objectName = "mcp_searxng_tls_crt", key = "tls.crt" },
            { objectName = "mcp_searxng_tls_key", key = "tls.key" },
          ]
        },
        {
          secretName = "mcp-searxng-auth"
          type       = "Opaque"
          data = [
            { objectName = "mcp_searxng_api_keys_csv", key = "api_keys_csv" },
          ]
        },
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "mcp"
        objects = yamlencode([
          { objectName = "mcp_searxng_tls_crt", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/mcp/mcp-searxng/tls", secretKey = "fullchain_pem" },
          { objectName = "mcp_searxng_tls_key", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/mcp/mcp-searxng/tls", secretKey = "privkey_pem" },
          { objectName = "mcp_searxng_api_keys_csv", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/mcp/mcp-searxng/auth", secretKey = "api_keys_csv" },
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.mcp,
    vault_kubernetes_auth_backend_role.mcp,
    vault_kv_secret_v2.mcp_searxng_tls,
    vault_kv_secret_v2.mcp_searxng_auth,
  ]
}
