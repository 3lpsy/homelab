# NetworkPolicies for the `litellm` namespace.
#
# Hosts: litellm + litellm-postgres. Both reach each other intra-ns.
# litellm proxies to upstream providers (Bedrock, DeepInfra) via the
# public internet — covered by the baseline's internet egress.

module "litellm_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.litellm.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}
