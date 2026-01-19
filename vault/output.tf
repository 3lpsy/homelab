# In vault/main.tf - add these outputs
output "vault_service_account_name" {
  value = kubernetes_service_account.vault.metadata[0].name
}

output "vault_namespace" {
  value = kubernetes_namespace.vault.metadata[0].name
}

output "vault_internal_address" {
  value = "http://vault.vault.svc.cluster.local:8200"
}
