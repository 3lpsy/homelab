# NetworkPolicies for the `tls-rotator` namespace.
#
# CronJob runs daily, renewing certs via lego over Tailscale and writing
# back to Vault on :8201. Today the Vault write goes via the pod's own
# Tailscale sidecar (NetPol-invisible). After the deferred CoreDNS
# rewrite for `vault.MAGIC_DOMAIN` lands, the write traverses the
# cluster network and the cross-ns egress allow below becomes
# load-bearing. Adding it now is harmless.
#
# Internet egress is required: lego performs DNS-01 challenges against
# Route53 (TCP 443 to AWS), and the Tailscale sidecar needs Headscale +
# DERP. Both covered by the baseline's internet egress.

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
