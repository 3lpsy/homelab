output "spc_name" {
  description = "SecretProviderClass name. Mount via secretProviderClass attribute on a CSI volume."
  value       = local.spc_name
}

output "config_secret_name" {
  description = "Name of the k8s Secret synced from Vault config. Reference via valueFrom.secretKeyRef or as a tls Secret volume."
  value       = local.config_secret_name
}

output "tls_secret_name" {
  description = "Name of the k8s Secret holding fullchain/privkey. Mount as a Secret volume in the nginx sidecar (kubernetes.io/tls type)."
  value       = local.tls_secret_name
}

output "fullchain_pem" {
  description = "ACME-issued fullchain PEM. Exposed for tls-rotator's local.rotated_certs and bootstrap day-zero issuance."
  value       = module.tls.fullchain_pem
  sensitive   = true
}

output "privkey_pem" {
  description = "ACME-issued private key PEM. Exposed for parity with fullchain_pem."
  value       = module.tls.privkey_pem
  sensitive   = true
}

output "vault_kv_path" {
  description = "Vault KV path prefix (e.g. \"grafana\"). Append /config or /tls for full paths."
  value       = local.vault_path
}

output "vault_role_name" {
  description = "Vault Kubernetes auth role name (matches roleName in the SPC). When manage_vault_auth=false, this is whatever the caller supplied."
  value       = local.role_name
}
