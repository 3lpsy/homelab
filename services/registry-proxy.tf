# Shared resources for the docker.io + ghcr.io pull-through caches.
#
# Two Deployments (registry-dockerio.tf, registry-ghcrio.tf) live in this
# namespace. They share:
#   - this namespace
#   - the ServiceAccount + RBAC (one Role lists both TS state secrets)
#   - the Vault policy + K8s auth role
#   - one PVC — mounted RWO by both pods, allowed because this is a
#     single-node cluster and local-path is hostPath under the hood. Each
#     Distribution writes to its own subPath of the shared PVC so blobs/
#     manifests from each upstream stay isolated.
#   - the netpol-baseline + exitnode-haproxy egress allow

resource "kubernetes_namespace" "registry_proxy" {
  metadata {
    name = "registry-proxy"
  }
}

resource "kubernetes_service_account" "registry_proxy" {
  metadata {
    name      = "registry-proxy"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }
  automount_service_account_token = false
}

# One Role listing every per-upstream tailscale-state Secret. Each
# tailscale-ingress module call below runs with manage_role=false so it
# does NOT create its own Role, only the state Secret + auth Secret +
# headscale key.
resource "kubernetes_role" "registry_proxy_tailscale" {
  metadata {
    name      = "registry-proxy-tailscale"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    resource_names = [
      "registry-dockerio-tailscale-state",
      "registry-ghcrio-tailscale-state",
    ]
    verbs = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "registry_proxy_tailscale" {
  metadata {
    name      = "registry-proxy-tailscale"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.registry_proxy_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.registry_proxy.metadata[0].name
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }
}

# Shared Vault policy granting read on every per-upstream KV path. Each
# service-tls-vault call below uses manage_vault_auth=false so the modules
# don't create competing policies/roles.
resource "vault_policy" "registry_proxy" {
  name = "registry-proxy-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/registry-dockerio/*" {
  capabilities = ["read"]
}
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/registry-ghcrio/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "registry_proxy" {
  backend                          = "kubernetes"
  role_name                        = "registry-proxy"
  bound_service_account_names      = ["registry-proxy"]
  bound_service_account_namespaces = ["registry-proxy"]
  token_policies                   = [vault_policy.registry_proxy.name]
  token_ttl                        = 86400
}

# Single shared cache PVC. Both Distribution containers (docker.io and
# ghcr.io upstreams) write here under separate `rootdirectory` subpaths,
# so blobs/manifests from each upstream stay in their own subtree.
#
# No `prevent_destroy` — every layer is regen-able by re-pulling on cache
# miss. Kopia explicitly excludes this PVC (cluster.tf).
resource "kubernetes_persistent_volume_claim" "registry_proxy_data" {
  metadata {
    name      = "registry-proxy-data"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = "100Gi"
      }
    }
  }
  wait_until_bound = false
}

# NetworkPolicies for the `registry-proxy` namespace.
#
# Reach paths:
#   - Kubelet image pulls — via the K3s node's Tailscale interface
#     (`registry-{dockerio,ghcrio}.MAGIC_DOMAIN` resolves through
#     systemd-resolved → tailscale0). Host-LOCAL source bypasses
#     NetworkPolicy structurally, so no in-cluster ingress rule is needed.
#   - BuildKit Jobs in the `builder` namespace pull through these proxies
#     for `FROM docker.io/...` / `FROM ghcr.io/...` lookups via
#     host_aliases mapping the FQDNs to the registry-dockerio /
#     registry-ghcrio Service ClusterIPs. TCP 443 ingress allowed below.
#   - Egress: each Distribution proxy reaches its upstream
#     (registry-1.docker.io / ghcr.io) via exitnode-haproxy:8888 (set as
#     HTTPS_PROXY in the per-upstream files), which load-balances across
#     the ProtonVPN exit-node tinyproxies.
module "registry_proxy_netpol_baseline" {
  source = "../templates/netpol-baseline"

  namespace    = kubernetes_namespace.registry_proxy.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

resource "kubernetes_network_policy" "registry_proxy_to_exitnode" {
  metadata {
    name      = "registry-proxy-to-exitnode"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.exitnode.metadata[0].name
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "8888"
      }
    }
  }
}

resource "kubernetes_network_policy" "registry_proxy_from_builder" {
  metadata {
    name      = "registry-proxy-from-builder"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.builder.metadata[0].name
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}
