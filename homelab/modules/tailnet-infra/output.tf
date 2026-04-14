output "nomad_server_preauth_key" {
  value     = headscale_pre_auth_key.nomad_server.key
  sensitive = true
}

output "tv_preauth_key" {
  value     = headscale_pre_auth_key.tv.key
  sensitive = true
}



output "ollama_preauth_key" {
  value     = headscale_pre_auth_key.ollama.key
  sensitive = true
}

# output "litellm_preauth_key" {
#   value     = headscale_pre_auth_key.litellm.key
#   sensitive = true
# }


output "user_map" {
  description = "Map of role keys to their created user IDs"
  value       = { for k, u in headscale_user.users : k => u.id }
}
