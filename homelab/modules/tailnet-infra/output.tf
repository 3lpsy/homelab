output "nomad_server_preauth_key" {
  value     = headscale_pre_auth_key.nomad_server.key
  sensitive = true
}

output "user_map" {
  description = "Map of usernames to their created user IDs"
  value = {
    personal         = headscale_user.personal_user.id
    mobile           = headscale_user.mobile_user.id
    tablet           = headscale_user.tablet_user.id
    deck             = headscale_user.deck_user.id
    devbox           = headscale_user.devbox_user.id
    nomad_server     = headscale_user.nomad_server_user.id
    vault_server     = headscale_user.vault_server_user.id
    nextcloud_server = headscale_user.nextcloud_server_user.id
    collabora_server = headscale_user.collabora_server_user.id
  }
}
