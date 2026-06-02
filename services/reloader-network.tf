# NetworkPolicies for the `reloader` namespace.
#
# Reloader's only data-plane traffic is to the K8s API (list/watch
# ConfigMaps/Secrets cluster-wide, patch Deployments/DaemonSets/StatefulSets).
# All cross-namespace work happens at the API layer, not at the pod
# network — Reloader never opens a connection to a target pod's IP.
# Baseline default-deny + kube-API egress is sufficient.

module "reloader_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace             = kubernetes_namespace.reloader.metadata[0].name
  pod_cidr              = var.k8s_pod_cidr
  service_cidr          = var.k8s_service_cidr
  allow_internet_egress = false
  allow_kube_api_egress = true
}
