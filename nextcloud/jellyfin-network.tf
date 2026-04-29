# NetworkPolicies for the `jellyfin` namespace.
#
# Single-pod namespace. Config + cache live on PVCs; no DB, no shared cache.
# Outbound only needs kube-dns + the tailnet sidecar — netpol-baseline covers
# both. Tailscale traffic exits through the sidecar's NET_ADMIN-managed
# interface, not via cluster netpol.

module "jellyfin_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.jellyfin.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}
