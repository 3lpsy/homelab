# NetworkPolicies for the `thunderbolt` namespace.
#
# Hosts: thunderbolt-backend, thunderbolt-frontend (nginx), keycloak,
# postgres, mongo, powersync. All cross-pod traffic is intra-namespace
# today (backend ↔ keycloak, backend ↔ mongo, powersync ↔ postgres).
#
# Backend reaches `searxng.MAGIC_DOMAIN` and `litellm.MAGIC_DOMAIN` over
# Tailscale today (NetPol-invisible). After the deferred CoreDNS rewrites,
# add cross-ns egress allows to `searxng:443` and `litellm:443` here.

module "thunderbolt_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.thunderbolt.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}
