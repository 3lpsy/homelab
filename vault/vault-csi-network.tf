# NetworkPolicies for the `vault-csi` namespace.
#
# The namespace is created by the Helm chart in csi.tf
# (`create_namespace = true`), so it isn't a `kubernetes_namespace`
# resource we can reference. We address it by literal name. K8s
# auto-applies the `kubernetes.io/metadata.name = vault-csi` label so
# the namespace_selector works without any extra labeling.

# Default-deny + intra-ns + DNS + K8s API egress.
# Internet egress is OFF — the CSI provider only talks to vault and the
# kube API.
module "vault_csi_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace             = "vault-csi"
  pod_cidr              = var.k8s_pod_cidr
  service_cidr          = var.k8s_service_cidr
  allow_internet_egress = false
  allow_kube_api_egress = true

  depends_on = [helm_release.vault_csi_provider]
}

# Cross-namespace egress: vault-csi → vault:8200 for every SecretProviderClass mount.
resource "kubernetes_network_policy" "vault_csi_to_vault" {
  depends_on = [helm_release.vault_csi_provider]

  metadata {
    name      = "vault-csi-to-vault"
    namespace = "vault-csi"
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.vault.metadata[0].name
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "8200"
      }
    }
  }
}
