module "mcp-shared-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = local.mcp_shared_fqdn
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "vault_kv_secret_v2" "mcp_shared_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "mcp/mcp-shared/tls"
  data_json = jsonencode({
    fullchain_pem = module.mcp-shared-tls.fullchain_pem
    privkey_pem   = module.mcp-shared-tls.privkey_pem
  })
}

# Shared SPC — used by the mcp-shared pod (TLS for nginx) and, starting in
# Phase 2 of the consolidation, by the app pods (`mcp-auth` Secret). The
# `mcp-auth` secretObject is defined here so Phase 2 only needs to flip env
# refs on the app Deployments.
resource "kubernetes_manifest" "mcp_shared_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-mcp-shared"
      namespace = kubernetes_namespace.mcp.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "mcp-shared-tls"
          type       = "kubernetes.io/tls"
          data = [
            { objectName = "mcp_shared_tls_crt", key = "tls.crt" },
            { objectName = "mcp_shared_tls_key", key = "tls.key" },
          ]
        },
        {
          secretName = "mcp-auth"
          type       = "Opaque"
          data = [
            { objectName = "mcp_shared_api_keys_csv", key = "api_keys_csv" },
            { objectName = "mcp_shared_path_salt", key = "path_salt" },
          ]
        },
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "mcp"
        objects = yamlencode([
          { objectName = "mcp_shared_tls_crt", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/mcp/mcp-shared/tls", secretKey = "fullchain_pem" },
          { objectName = "mcp_shared_tls_key", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/mcp/mcp-shared/tls", secretKey = "privkey_pem" },
          { objectName = "mcp_shared_api_keys_csv", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/mcp/auth", secretKey = "api_keys_csv" },
          { objectName = "mcp_shared_path_salt", secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/mcp/auth", secretKey = "path_salt" },
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.mcp,
    vault_kubernetes_auth_backend_role.mcp,
    vault_kv_secret_v2.mcp_shared_tls,
    vault_kv_secret_v2.mcp_auth,
  ]
}
