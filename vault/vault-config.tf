resource "kubernetes_config_map" "vault_config" {
  metadata {
    name      = "vault-config"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  data = {
    "vault.hcl" = templatefile("${path.module}/../data/vault/vault.hcl.tpl", {})
  }
}

resource "kubernetes_config_map" "vault_unseal_script" {
  metadata {
    name      = "vault-unseal-script"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
  data = {
    "unseal.sh" = templatefile("${path.module}/../data/scripts/unseal.sh.tpl", {})
  }
}
