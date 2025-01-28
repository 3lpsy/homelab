output "nomad_server_preauth_key" {
  value     = headscale_pre_auth_key.nomad_server.key
  sensitive = true
}
output "vault_server_preauth_key" {
  value     = headscale_pre_auth_key.vault_server.key
  sensitive = true
}
