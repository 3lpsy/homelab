# TLS cert

module "mcp-duckduckgo-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = local.mcp_duckduckgo_fqdn
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "vault_kv_secret_v2" "mcp_duckduckgo_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "mcp/mcp-duckduckgo/tls"
  data_json = jsonencode({
    fullchain_pem = module.mcp-duckduckgo-tls.fullchain_pem
    privkey_pem   = module.mcp-duckduckgo-tls.privkey_pem
  })
}

resource "kubernetes_manifest" "mcp_duckduckgo_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-mcp-duckduckgo"
      namespace = kubernetes_namespace.mcp.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "mcp-duckduckgo-tls"
          type       = "kubernetes.io/tls"
          data = [
            { objectName = "mcp_duckduckgo_tls_crt", key = "tls.crt" },
            { objectName = "mcp_duckduckgo_tls_key", key = "tls.key" },
          ]
        }
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "mcp"
        objects = yamlencode([
          { objectName = "mcp_duckduckgo_tls_crt", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/mcp/mcp-duckduckgo/tls", secretKey = "fullchain_pem" },
          { objectName = "mcp_duckduckgo_tls_key", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/mcp/mcp-duckduckgo/tls", secretKey = "privkey_pem" },
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.mcp,
    vault_kubernetes_auth_backend_role.mcp,
    vault_kv_secret_v2.mcp_duckduckgo_tls,
  ]
}
