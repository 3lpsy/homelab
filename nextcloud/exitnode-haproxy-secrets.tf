# Tailnet wiring for exitnode-haproxy. Joins the tailnet as a plain member
# under exit_node_user (group:exitnodes) so tailnet clients can point
# HTTP_PROXY at exitnode-haproxy:8888 and get balance-random rotation across
# the in-cluster ProtonVPN tinyproxy pods.
#
# Deliberately NOT tagged tag:exitnode — that tag triggers
# autoApprovers.exitNode and would advertise this node as an OS-level
# Tailscale exit node, which it is not (haproxy only forwards TCP :8888).

resource "headscale_pre_auth_key" "exitnode_haproxy" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.exit_node_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "exitnode_haproxy_tailscale_auth" {
  metadata {
    name      = "exitnode-haproxy-tailscale-auth"
    namespace = kubernetes_namespace.exitnode.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.exitnode_haproxy.key
  }
}

resource "kubernetes_secret" "exitnode_haproxy_tailscale_state" {
  metadata {
    name      = "exitnode-haproxy-tailscale-state"
    namespace = kubernetes_namespace.exitnode.metadata[0].name
  }
  type = "Opaque"

  lifecycle {
    ignore_changes = [data, type]
  }
}

# TLS bootstrap. Initial cert issued via ACME; tls-rotator
# (nextcloud/tls-rotator.tf) owns ongoing renewal post-bootstrap. Vault KV
# is the source of truth, mounted into the pod via CSI as a kubernetes.io/tls
# secret. An init container concatenates fullchain + privkey into a single
# PEM file, since haproxy's `ssl crt` directive expects combined PEM.
module "exitnode-haproxy-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.exitnode_haproxy_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "vault_kv_secret_v2" "exitnode_haproxy_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "exitnode-haproxy/tls"
  data_json = jsonencode({
    fullchain_pem = module.exitnode-haproxy-tls.fullchain_pem
    privkey_pem   = module.exitnode-haproxy-tls.privkey_pem
  })

  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "vault_policy" "exitnode_haproxy" {
  name = "exitnode-haproxy-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/exitnode-haproxy/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "exitnode_haproxy" {
  backend                          = "kubernetes"
  role_name                        = "exitnode-haproxy"
  bound_service_account_names      = [kubernetes_service_account.exitnode.metadata[0].name]
  bound_service_account_namespaces = [kubernetes_namespace.exitnode.metadata[0].name]
  token_policies                   = [vault_policy.exitnode_haproxy.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "exitnode_haproxy_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-exitnode-haproxy"
      namespace = kubernetes_namespace.exitnode.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "exitnode-haproxy-tls"
          type       = "kubernetes.io/tls"
          data = [
            { objectName = "tls_crt", key = "tls.crt" },
            { objectName = "tls_key", key = "tls.key" },
          ]
        },
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "exitnode-haproxy"
        objects = yamlencode([
          {
            objectName = "tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/exitnode-haproxy/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/exitnode-haproxy/tls"
            secretKey  = "privkey_pem"
          },
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.exitnode,
    vault_kubernetes_auth_backend_role.exitnode_haproxy,
    vault_kv_secret_v2.exitnode_haproxy_tls,
    vault_policy.exitnode_haproxy,
  ]
}
