terraform {
  required_providers {
    headscale = {
      source                = "awlsring/headscale"
      version               = "~>0.4.0"
      configuration_aliases = [headscale]
    }
  }
}

data "local_file" "api_key" {
  filename = "${path.root}/../headscale.key"
}

resource "headscale_user" "users" {
  for_each = var.tailnet_users
  name     = each.value
  # lifecycle {
  #   prevent_destroy = true
  # }
}

resource "headscale_pre_auth_key" "nomad_server" {
  user = headscale_user.users["nomad_server_user"].id
}

resource "headscale_pre_auth_key" "tv" {
  user           = headscale_user.users["tv_user"].id
  reusable       = true
  time_to_expire = "3y"
}

resource "headscale_pre_auth_key" "exit_node" {
  user           = headscale_user.users["exit_node_user"].id
  reusable       = true
  time_to_expire = "3y"
}
# resource "headscale_user" "test_user" {
#   name = "test_user"
# }
# resource "headscale_pre_auth_key" "test_user" {
#   user = "test_user"
# }
