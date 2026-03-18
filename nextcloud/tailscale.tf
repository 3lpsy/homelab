# Headscape PAKs and K3s Secret

# Generate Headscale pre-auth key
resource "headscale_pre_auth_key" "nextcloud_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.nextcloud_server_user
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

# Generate Headscale pre-auth key for Collabora
resource "headscale_pre_auth_key" "collabora_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.collabora_server_user
  reusable       = true
  time_to_expire = "1y"
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

# Immich uses nextcloud user for now
resource "headscale_pre_auth_key" "immich_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.nextcloud_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "immich_tailscale_auth" {
  metadata {
    name      = "immich-tailscale-auth"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.immich_server.key
  }
}

# Pihole
resource "headscale_pre_auth_key" "pihole_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.pihole_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "pihole_tailscale_auth" {
  metadata {
    name      = "pihole-tailscale-auth"
    namespace = kubernetes_namespace.pihole.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.pihole_server.key
  }
}

# Registry
resource "headscale_pre_auth_key" "registry_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.registry_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "registry_tailscale_auth" {
  metadata {
    name      = "registry-tailscale-auth"
    namespace = kubernetes_namespace.registry.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.registry_server.key
  }
}

# Radicale

resource "headscale_pre_auth_key" "radicale_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.calendar_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "radicale_tailscale_auth" {
  metadata {
    name      = "radicale-tailscale-auth"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.radicale_server.key
  }
}
