# NetworkPolicies for the `navidrome` namespace.
#
# Single-pod namespace. Library bytes are on a PVC; no DB, no shared cache.
# Outbound only needs kube-dns + the tailnet sidecar — netpol-baseline covers
# both.

module "navidrome_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.navidrome.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}
