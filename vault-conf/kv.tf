resource "vault_mount" "kv" {
  path = "secret"
  type = "kv-v2"
}

resource "kubernetes_secret" "vault_unseal_keys" {
  metadata {
    name      = "vault-unseal-keys"
    namespace = data.terraform_remote_state.vault.outputs.vault_namespace
  }
  type = "Opaque"
  data = {
    key1 = var.vault_unseal_key
  }
}
