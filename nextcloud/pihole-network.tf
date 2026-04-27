# NetworkPolicies for the `pihole` namespace.
#
# Single-pod namespace. Pihole serves DNS to tailnet devices via its
# Tailscale sidecar (NetPol-invisible). Internet egress (covered by
# baseline) is required for Pihole's upstream DNS resolvers.

module "pihole_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.pihole.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}
