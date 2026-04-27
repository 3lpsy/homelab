# NetworkPolicies for the `registry-proxy` namespace.
#
# Reach paths:
#   - Kubelet image pulls — via the K3s node's Tailscale interface
#     (`registry-proxy.MAGIC_DOMAIN` resolves through systemd-resolved →
#     tailscale0). Host-LOCAL source bypasses NetworkPolicy structurally,
#     so no in-cluster ingress rule is needed.
#   - Trivy on admin host — same path (tailnet → host net stack).
#   - Egress: the proxy itself has to reach `registry-1.docker.io` over
#     the public internet. Allow all egress for now; restrict later if
#     desired.

module "registry_proxy_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.registry_proxy.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}
