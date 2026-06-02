# NetworkPolicies for the `tls-rotator` namespace.
#
# CronJob runs daily, renewing certs via lego (DNS-01 against Route53)
# and writing back to Vault on :8201 via the cluster network — pod uses
# host_aliases pinning `vault.<hs>.<magic>` to the vault Service
# ClusterIP. The cross-ns egress allow below is load-bearing.
#
# Internet egress is required for DNS-01 (TCP 443 to AWS APIs) and
# in-cluster ACME validation traffic — covered by the baseline's
# internet egress.

module "tls_rotator_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.tls_rotator.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

# Cross-namespace egress: tls-rotator → vault:8201 (cert writes).
resource "kubernetes_network_policy" "tls_rotator_to_vault" {
  metadata {
    name      = "tls-rotator-to-vault"
    namespace = kubernetes_namespace.tls_rotator.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "vault"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "8201"
      }
    }
  }
}

