
output "kv_mount_path" {
  value = vault_mount.kv.path
}

output "zitadel_domain" {
  description = "Tailnet hostname for the Zitadel pod (no tailnet suffix). Consumed by services/tls-rotator.tf."
  value       = var.zitadel_domain
}

output "zitadel_cluster_ip" {
  description = "ClusterIP of the Zitadel Service. In-cluster OIDC consumers pin oidc.<tailnet> to this IP via host_aliases so SNI + TLS validate against the LE cert without going through tailscale egress."
  value       = kubernetes_service.zitadel.spec[0].cluster_ip
}

output "smtp_reader_policy_name" {
  description = "Vault policy name granting read on secret/data/smtp/config. Attach to per-service Vault auth roles that need SMTP creds."
  value       = vault_policy.smtp_reader.name
}

output "smtp_kv_path" {
  description = "Vault KV path (relative to kv_mount_path) where SMTP creds are stored. Used in SecretProviderClass `objects` lists."
  value       = vault_kv_secret_v2.smtp.name
}
