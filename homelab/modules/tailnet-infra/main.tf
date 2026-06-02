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
  # lifecycle {
  #   prevent_destroy = true
  # }
}

# Reusable so every cluster node (delphi server + artemis agent, and any
# future node) joins the tailnet under the same `nomad_server_user`
# identity → `group:node-server`. acls_self covers node↔node traffic
# (agent→server 6443 / kubelet 10250 / flannel 51820), so no ACL change is
# needed when a node is added. 3y expiry matches the other infra keys.
resource "headscale_pre_auth_key" "nomad_server" {
  user           = headscale_user.users["nomad_server_user"].id
  reusable       = true
  time_to_expire = "3y"
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

# Bootstrap key for the human operator on a fresh deployment. Workflow:
# `terraform apply homelab` → grab the surfaced preauth key from outputs
# → `tailscale up --authkey=<key>` from a laptop → continue rolling out
# vault → vault-conf → services → services-conf using the bootstrapped
# tailnet identity. After services is up and Zitadel exists, switch the
# device to OIDC (`tailscale logout && tailscale up --login-server=...`)
# and let the provisioner key expire.
#
# Reusable so a second device can join during bootstrap if needed; 30d
# expiry caps blast radius if leaked.
resource "headscale_pre_auth_key" "provisioner" {
  user           = headscale_user.users["provisioner_user"].id
  reusable       = true
  time_to_expire = "30d"
}

# Group definitions and per-service ACL partials live in acls.tf.
# This file holds resource declarations only.

locals {
  acl_policy = {
    groups = local.acl_groups
    autoApprovers = {
      exitNode = ["tag:exitnode"]
      # Auto-approve K8s pod-CIDR subnet route advertised by delphi.
      # Lets laptop / other tailnet clients reach pod IPs (10.42.x.x) via
      # delphi without kubectl port-forward. Requires NetworkPolicy
      # permitting tailnet ingress to the destination namespace —
      # kube-router default-deny will otherwise drop the forwarded
      # packet at delphi's FORWARD chain, even though this route
      # advertisement is approved.
      routes = {
        (var.k8s_pod_cidr) = ["group:node-server"]
      }
    }
    tagOwners = merge(
      { "tag:exitnode" = ["group:exitnodes"] },
      # Personal device-class tags. Declaration here is what makes the tag
      # name valid for assignment — even admin-side `headscale nodes tag`
      # rejects undeclared tags. Owner list also gates client-side
      # `--advertise-tags=` (CLI clients only; iOS/macOS GUI lacks the
      # flag, so those nodes get tagged server-side via headscale CLI
      # after first registration).
      var.personal_user_oidc_name == "" ? {} : {
        "tag:personal-roaming" = ["${var.personal_user_oidc_name}@"]
      }
    )
    hosts = {}
    acls  = local.acl_acls
  }
}

resource "headscale_policy" "main" {
  policy = jsonencode(local.acl_policy)
}
