# Shared resources for the docker.io + ghcr.io pull-through caches.
#
# Two Deployments (registry-dockerio.tf, registry-ghcrio.tf) live in this
# namespace. They share:
#   - this namespace
#   - the ServiceAccount + RBAC (one Role lists both TS state secrets)
#   - the Vault policy + K8s auth role (registry-proxy-secrets.tf)
#   - one PVC (registry-proxy-pvc.tf) — mounted RWO by both pods, allowed
#     because this is a single-node cluster and local-path is hostPath
#     under the hood. Each Distribution writes to its own subPath of the
#     shared PVC so blobs/manifests from each upstream stay isolated.
#   - the netpol-baseline + exitnode-haproxy egress allow
#     (registry-proxy-network.tf)
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
