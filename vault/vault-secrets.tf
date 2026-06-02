resource "headscale_pre_auth_key" "vault_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.vault_server_user
  reusable       = true
  time_to_expire = "1y"
}

module "vault-infra-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.vault_server_host_name}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = {
    acme = acme
  }
}

resource "kubernetes_service_account" "vault" {
  metadata {
    name      = "vault"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_secret" "tailscale_state" {
  metadata {
    name      = "tailscale-state"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
  type = "Opaque"

  lifecycle {
    ignore_changes = [data, type]
  }
}

resource "kubernetes_role" "tailscale" {
  metadata {
    name      = "tailscale"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "tailscale" {
  metadata {
    name      = "tailscale"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.vault.metadata[0].name
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
}

# Vault needs to validate service account tokens from other pods via the
# Kubernetes TokenReview API. Without this, CSI driver auth fails with 403.
resource "kubernetes_cluster_role" "vault_token_reviewer" {
  metadata {
    name = "vault-token-reviewer"
  }

  rule {
    api_groups = ["authentication.k8s.io"]
    resources  = ["tokenreviews"]
    verbs      = ["create"]
  }

  rule {
    api_groups = ["authorization.k8s.io"]
    resources  = ["subjectaccessreviews"]
    verbs      = ["create"]
  }
}

resource "kubernetes_cluster_role_binding" "vault_token_reviewer" {
  metadata {
    name = "vault-token-reviewer-binding"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.vault_token_reviewer.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.vault.metadata[0].name
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
}

resource "kubernetes_secret" "tailscale_auth" {
  metadata {
    name      = "tailscale-auth"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  type = "Opaque"

  data = {
    TS_AUTHKEY = headscale_pre_auth_key.vault_server.key
  }
  wait_for_service_account_token = false # import artifact
}

resource "kubernetes_secret" "vault_tls" {
  metadata {
    name      = "vault-tls"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = module.vault-infra-tls.fullchain_pem
    "tls.key" = module.vault-infra-tls.privkey_pem
  }
}

# Placeholder unseal key secret. vault-conf overwrites with real key after import.
resource "kubernetes_secret" "vault_unseal_keys" {
  metadata {
    name      = "vault-unseal-keys"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
  type = "Opaque"
  data = {
    key1 = var.vault_unseal_key
  }
  lifecycle {
    ignore_changes = [data]
  }
}

# Vault NetworkPolicies moved to vault-network.tf (default-deny + cross-ns
# allow pattern used cluster-wide).
