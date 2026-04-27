terraform {
  required_providers {
    headscale = {
      source                = "awlsring/headscale"
      version               = "~>0.5.0"
      configuration_aliases = [headscale]
    }
  }
}

data "local_file" "api_key" {
  filename = var.headscale_key_path
}

resource "headscale_user" "users" {
  for_each = var.tailnet_users
  name     = each.value
  lifecycle {
    prevent_destroy = true
  }
}

resource "headscale_pre_auth_key" "nomad_server" {
  user = headscale_user.users["nomad_server_user"].id
}

resource "headscale_pre_auth_key" "tv" {
  user           = headscale_user.users["tv_user"].id
  reusable       = true
  time_to_expire = "3y"
}


resource "headscale_pre_auth_key" "ollama" {
  user           = headscale_user.users["ollama_server_user"].id
  reusable       = true
  time_to_expire = "3y"
}

resource "headscale_pre_auth_key" "headscale_host" {
  user           = headscale_user.users["headscale_host_user"].id
  reusable       = true
  time_to_expire = "3y"
}

# Group definitions and per-service ACL partials live in acls.tf.
# This file holds resource declarations only.

locals {
  acl_policy = {
    groups        = local.acl_groups
    autoApprovers = { exitNode = ["tag:exitnode"] }
    tagOwners     = { "tag:exitnode" = ["group:exitnodes"] }
    hosts         = {}
    acls          = local.acl_acls
  }
}

resource "headscale_policy" "main" {
  policy = jsonencode(local.acl_policy)
}
