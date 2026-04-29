# NetworkPolicies for the `radicale` namespace.
#
# Single-pod namespace. Radicale's storage is on a PVC and DB writes go
# to the shared Postgres in the `nextcloud` namespace via Tailscale (the
# pod's own TS sidecar carries that traffic; NetPol-invisible).

module "radicale_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.radicale.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}
