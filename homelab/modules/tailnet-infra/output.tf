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

output "headscale_host_preauth_key" {
  value     = headscale_pre_auth_key.headscale_host.key
  sensitive = true
}

# output "litellm_preauth_key" {
#   value     = headscale_pre_auth_key.litellm.key
#   sensitive = true
# }


output "user_map" {
  description = "Map of role keys to their created user IDs (numeric). Use for headscale_pre_auth_key.user and other resources that take an ID."
  value       = { for k, u in headscale_user.users : k => u.id }
}

output "user_name_map" {
  description = "Map of role keys to their tailnet usernames. Use this when building tailnet hostnames (e.g. <name>.<magic_subdomain>)."
  value       = { for k, u in headscale_user.users : k => u.name }
}
