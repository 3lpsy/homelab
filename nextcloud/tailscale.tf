
# Generate Headscale pre-auth key
resource "headscale_pre_auth_key" "nextcloud_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.nextcloud_server
  reusable       = true
  time_to_expire = "1y"
}

# Generate Headscale pre-auth key for Collabora
resource "headscale_pre_auth_key" "collabora_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.collabora_server
  reusable       = true
  time_to_expire = "1y"
}

# Tailscale auth secret
resource "kubernetes_secret" "tailscale_auth" {
  metadata {
    name      = "tailscale-auth"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  type = "Opaque"

  data = {
    TS_AUTHKEY = headscale_pre_auth_key.nextcloud_server.key
  }
}

# Tailscale auth secret for Collabora
resource "kubernetes_secret" "collabora_tailscale_auth" {
  metadata {
    name      = "collabora-tailscale-auth"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  type = "Opaque"

  data = {
    TS_AUTHKEY = headscale_pre_auth_key.collabora_server.key
  }
}
