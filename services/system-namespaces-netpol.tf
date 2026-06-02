# Default-deny NetworkPolicies for the k8s-built-in system namespaces that
# don't host any pods we care about (`default`, `kube-public`,
# `kube-node-lease`). All three are auto-created by k8s and are empty in
# this cluster:
#   - `default`: pods only land here on misconfiguration; deny-all is
#     defensive.
#   - `kube-public`: holds the cluster-info ConfigMap, accessed via the API
#     server (not via pod networking) — netpol is a no-op for traffic but
#     satisfies Kubescape C-0054 (every namespace should have ≥1 netpol).
#   - `kube-node-lease`: holds Lease objects (kubelet heartbeats); no pods.
#
# The netpol is intentionally minimal (no allow rules). It selects every
# pod (`pod_selector {}`) and sets both Ingress and Egress in the
# `policy_types`, with no rule blocks → all pod-level traffic denied. Has
# no effect today because the namespaces have no pods; future accidental
# pod placement gets isolated automatically.
resource "kubernetes_network_policy" "system_namespace_default_deny" {
  for_each = toset(["default", "kube-public", "kube-node-lease"])

  metadata {
    name      = "default-deny-all"
    namespace = each.key
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}
