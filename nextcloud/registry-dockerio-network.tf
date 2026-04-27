# NetworkPolicies for the `registry-dockerio` namespace.
#
# Reach paths:
#   - Kubelet image pulls — via the K3s node's Tailscale interface
#     (`registry-dockerio.MAGIC_DOMAIN` resolves through systemd-resolved →
#     tailscale0). Host-LOCAL source bypasses NetworkPolicy structurally,
#     so no in-cluster ingress rule is needed.
#   - Trivy on admin host — same path (tailnet → host net stack).
#   - Egress: the proxy itself has to reach `registry-1.docker.io` over
#     the public internet. Allow all egress for now; restrict later if
#     desired.

module "registry_dockerio_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.registry_dockerio.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

# Egress to the rotating exit-node front-end. The Distribution proxy uses
# HTTPS_PROXY (set in registry-dockerio.tf) to send upstream pulls through
# exitnode-haproxy:8888, which load-balances them across all configured
# WireGuard tunnels — dodging Docker Hub's per-IP anonymous rate limit.
# K3s ships with kube-router as the NetworkPolicy controller (separate from
# flannel CNI), so this rule is functionally enforced.
resource "kubernetes_network_policy" "registry_dockerio_to_exitnode" {
  metadata {
    name      = "registry-dockerio-to-exitnode"
    namespace = kubernetes_namespace.registry_dockerio.metadata[0].name
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
